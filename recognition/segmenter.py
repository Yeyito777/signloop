"""Sign start/end detection: IDLE -> POSSIBLE_SIGN -> SIGN_IN_PROGRESS -> SIGN_COMPLETE -> PREDICTION.

Deliberately simple and deterministic (integer milliseconds, no learned parameters) so it can
be ported line-for-line to Swift and checked against golden traces. Thresholds are in
palm-lengths per second, i.e. invariant to camera distance, and are meant to be tuned on
validation recordings (recognition.replay.tune_segmenter); the defaults are starting points,
not measured values.

  IDLE          no settled hand. A hand that is still touching the frame border is "entering"
                and cannot start anything.
  POSSIBLE_SIGN a hand has been fully inside the frame for settle_ms; waiting for movement
                (sign begins) or a long stable hold (static sign).
  SIGN_IN_PROGRESS  movement onset seen; buffering until the hand rests, leaves, or max_ms.
  SIGN_COMPLETE emitted once with the buffered frames (pre-roll and tail included).
  PREDICTION    the recognizer owns the segment; new segments are refused until finish().

After a prediction the segmenter is *unarmed*: a hand that merely stays in view cannot fire
again (no repeated predictions from one sign). It re-arms when the hand leaves for
rearm_absent_ms, or when a fresh movement onset occurs (which then starts the next sign).
"""
from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
import math

import numpy as np

from .features import N_JOINTS, frames_to_raw

BORDER = 0.02  # normalized image margin; a palm-core joint closer than this to an edge counts as "entering"
PALM_CORE = (0, 5, 9, 13, 17)  # wrist + knuckles; fingertips may leave the frame without the hand "entering"


class State(str, Enum):
    IDLE = "idle"
    POSSIBLE = "possible_sign"
    IN_PROGRESS = "sign_in_progress"
    COMPLETE = "sign_complete"
    PREDICTION = "prediction"


@dataclass(frozen=True)
class SegmenterConfig:
    settle_ms: int = 200
    lag_frames: int = 5
    shape_weight: float = 1.0   # handshape change counts as movement (open->close signs)
    e_on: float = 1.2
    e_off: float = 0.4
    onset_ms: int = 100
    hold_ms: int = 250
    lost_ms: int = 200
    min_ms: int = 400
    max_ms: int = 3000
    preroll_ms: int = 200
    tail_ms: int = 100
    dwell_ms: int = 600
    rearm_absent_ms: int = 300
    min_gap_ms: int = 500
    max_frame_gap_ms: int = 150


@dataclass
class Segment:
    frames: list
    start_ms: int
    end_ms: int
    reason: str  # movement_rest | hand_left | max_duration | static_hold


@dataclass
class _Obs:
    t: int
    frame: dict
    present: bool
    inside: bool
    slots: dict          # slot -> (xy (21,2) aspect-corrected, scale)


def summarize(frame: dict, t: int) -> _Obs:
    """Aspect/mirror-corrected joint positions per slot, plus whether every present hand is inside the image."""
    slots, inside = {}, True
    aspect = float(frame.get("imageAspectRatio") or 1.0)
    for hand in frame.get("hands", []):
        j = hand.get("joints", [])
        if len(j) != N_JOINTS:
            continue
        xy = np.array([[p["x"], p["y"]] for p in j], dtype=np.float64)
        if not np.all(np.isfinite(xy)):
            continue
        core = xy[list(PALM_CORE)]
        if core.min() < BORDER or core.max() > 1 - BORDER:
            inside = False
        mirrored = frame.get("mirrored")
        mirrored = True if mirrored is None else bool(mirrored)
        side = hand.get("handedness")
        if not mirrored:
            side = {"Left": "Right", "Right": "Left"}.get(side, side)
            xy[:, 0] = 1 - xy[:, 0]
        if side not in ("Left", "Right"):
            continue
        xy[:, 0] *= aspect
        spokes = [np.linalg.norm(xy[k] - xy[0]) for k in (5, 9, 13, 17)]
        scale = float(np.mean(spokes))
        if scale < 0.015:
            continue
        slots[0 if side == "Left" else 1] = (xy, scale)
    present = bool(slots)
    return _Obs(t, frame, present, present and inside, slots)


def energy(cur: _Obs, ref: _Obs | None, max_gap: int, shape_weight: float = 1.0) -> float | None:
    """Palm-lengths/second between cur and an earlier observation. None if not comparable.
    max of centroid translation speed and the weighted internal (handshape) change speed."""
    if ref is None or cur.t <= ref.t or cur.t - ref.t > max_gap * 4:
        return None
    dt = (cur.t - ref.t) / 1000.0
    best = None
    for slot, (xy, scale) in cur.slots.items():
        if slot not in ref.slots:
            continue
        rxy, rscale = ref.slots[slot]
        s = (scale + rscale) / 2
        c0, c1 = rxy.mean(0), xy.mean(0)
        trans = float(np.linalg.norm(c1 - c0)) / s / dt
        shape = float(np.linalg.norm((xy - c1) - (rxy - c0), axis=1).mean()) / s / dt
        e = max(trans, shape_weight * shape)
        best = e if best is None else max(best, e)
    return best


class Segmenter:
    def __init__(self, cfg: SegmenterConfig = SegmenterConfig()):
        self.cfg = cfg
        self.reset()

    def reset(self):
        self.state = State.IDLE
        self.obs: list[_Obs] = []
        self.armed = True
        self.settle_start = None
        self.possible_start = None
        self.onset = None
        self.seg_start = None
        self.last_active = None
        self.rest_since = None
        self.absent_since = None
        self.gone_since = None
        self.last_finish = None
        self.last_t = None

    # -- helpers
    def _slice(self, start, end):
        return [o.frame for o in self.obs if start <= o.t <= end]

    def _trim(self, t):
        horizon = t - (self.cfg.max_ms + 2000)
        self.obs = [o for o in self.obs if o.t >= horizon]

    def finish(self, t_ms: int):
        """Recognizer has consumed the segment. Refractory begins; segmenter is unarmed."""
        self.state = State.IDLE
        self.armed = False
        self.last_finish = t_ms
        self.settle_start = self.possible_start = self.onset = self.seg_start = None
        self.rest_since = self.absent_since = self.gone_since = None

    def update(self, frame: dict):
        """Feed one frame. Returns a Segment exactly once per completed attempt, else None."""
        cfg = self.cfg
        t = int(frame["timestampMS"])
        if self.last_t is not None and (t <= self.last_t or t - self.last_t > cfg.max_frame_gap_ms * 4):
            keep_state = self.state == State.PREDICTION
            last_finish = self.last_finish
            self.reset()  # stalled/out-of-order camera: drop any partial attempt
            if keep_state:
                self.state = State.PREDICTION
            self.last_finish = last_finish
        self.last_t = t
        obs = summarize(frame, t)
        ref = None
        # Reference = the observation ~lag_frames back that actually contains a hand; a dropped
        # frame must not blind the motion estimate (search up to 3 frames further back).
        for back in range(cfg.lag_frames, cfg.lag_frames + 4):
            if len(self.obs) >= back and self.obs[-back].present:
                ref = self.obs[-back]
                break
        e = energy(obs, ref, cfg.max_frame_gap_ms, cfg.shape_weight) if obs.present else None
        self.obs.append(obs)
        self._trim(t)
        if self.state == State.PREDICTION:
            return None

        moving = e is not None and e >= cfg.e_on
        resting = obs.present and (e is None or e < cfg.e_off)

        if obs.present:
            self.gone_since = None
        elif self.gone_since is None:
            self.gone_since = t
        if not self.armed and self.gone_since is not None and t - self.gone_since >= cfg.rearm_absent_ms:
            self.armed = True

        gap_ok = self.last_finish is None or t - self.last_finish >= cfg.min_gap_ms
        # A tracker dropout shorter than lost_ms neither starts nor cancels anything.
        brief_dropout = (not obs.present) and self.gone_since is not None and t - self.gone_since < cfg.lost_ms

        if self.state in (State.IDLE, State.POSSIBLE) and brief_dropout:
            return None

        if self.state == State.IDLE:
            if not obs.inside:
                self.settle_start = None
                self.onset = None
                return None
            if self.settle_start is None:
                self.settle_start = t
            settled = t - self.settle_start >= cfg.settle_ms
            if moving and gap_ok:
                self.onset = self.onset if self.onset is not None else t
                if settled and t - self.onset >= cfg.onset_ms:
                    self.armed = True   # fresh movement re-arms a recognizer left unarmed by the last prediction
            else:
                self.onset = None
            if self.armed and gap_ok and settled:
                # always pass through POSSIBLE_SIGN; onset (if already moving) carries over
                self.state = State.POSSIBLE
                self.possible_start = self.settle_start
                self.rest_since = t if resting else None
            return None

        if self.state == State.POSSIBLE:
            if not obs.inside:
                self.state = State.IDLE
                self.settle_start = self.onset = self.rest_since = None
                return None
            if moving:
                self.onset = self.onset if self.onset is not None else t
                self.rest_since = None
                if t - self.onset >= cfg.onset_ms:
                    return self._begin(max(self.possible_start, self.onset - cfg.preroll_ms), t)
                return None
            self.onset = None
            if resting:
                self.rest_since = self.rest_since if self.rest_since is not None else t
                if t - self.rest_since >= cfg.dwell_ms:  # static sign: the held pose is the sign
                    return self._complete(self.rest_since, t, "static_hold")
            else:
                self.rest_since = None
            return None

        if self.state == State.IN_PROGRESS:
            if obs.present:
                self.absent_since = None
            elif self.absent_since is None:
                self.absent_since = t
            if e is not None and e >= cfg.e_off:
                self.last_active, self.rest_since = t, None
            elif obs.present and self.rest_since is None:
                self.rest_since = t
            if self.absent_since is not None and t - self.absent_since >= cfg.lost_ms:
                return self._complete(self.seg_start, self.absent_since, "hand_left")
            if self.rest_since is not None and t - self.rest_since >= cfg.hold_ms:
                return self._complete(self.seg_start, (self.last_active or t) + cfg.tail_ms, "movement_rest")
            if t - self.seg_start >= cfg.max_ms:
                return self._complete(self.seg_start, t, "max_duration")
        return None

    def _begin(self, start, t):
        self.state = State.IN_PROGRESS
        self.armed = True
        self.seg_start = start
        self.last_active = t
        self.rest_since = None
        self.absent_since = None
        self.onset = None
        return None

    def _complete(self, start, end, reason):
        self.state = State.COMPLETE
        frames = self._slice(start, end)
        seg = Segment(frames, int(start), int(end), reason)
        self.state = State.PREDICTION
        if end - start < self.cfg.min_ms or len(frames) < 6 or not any(f.get("hands") for f in frames):
            self.finish(int(end))
            self.armed = True     # a discarded blip must not lock the recognizer out
            self.last_finish = None
            return None
        return seg
