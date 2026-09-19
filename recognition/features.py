"""Landmark frames -> normalized, temporally resampled two-stream features.

Pipeline:  frames (app schema)  ->  RawSequence  ->  resample(T)  ->  Features

Two streams are kept separate on purpose:
  A. shape  : what the hand is doing (wrist-centred, palm-scaled, bone vectors,
              joint angles, fingertip relations, palm normal, in-plane orientation)
  B. motion : where/how it moves (position relative to the signer's own start and,
              when available, to a face/torso anchor; velocity; acceleration)

Missing data is explicit: every hand slot has a mask (1 observed, 0.5 bridged across a
short gap, 0 missing) and missing values are zero, never fabricated.
"""
from __future__ import annotations

from dataclasses import dataclass, field
import math

import numpy as np

N_JOINTS = 21
# MediaPipe hand topology. PARENT[j] is the joint j's bone connects to.
PARENT = np.array([-1, 0, 1, 2, 3, 0, 5, 6, 7, 0, 9, 10, 11, 0, 13, 14, 15, 0, 17, 18, 19])
BONES = [(int(PARENT[j]), j) for j in range(1, N_JOINTS)]
FINGERTIPS = (4, 8, 12, 16, 20)
# (a, b, c): angle at b between b->a and b->c.
ANGLE_TRIPLES = [(0, 1, 2), (1, 2, 3), (2, 3, 4),
                 (0, 5, 6), (5, 6, 7), (6, 7, 8),
                 (0, 9, 10), (9, 10, 11), (10, 11, 12),
                 (0, 13, 14), (13, 14, 15), (14, 15, 16),
                 (0, 17, 18), (17, 18, 19), (18, 19, 20)]
ABDUCTION = [(5, 9), (9, 13), (13, 17), (1, 5)]  # angle between wrist->MCP spokes
SLOT_LEFT, SLOT_RIGHT = 0, 1

NODE_C = 6                                   # xyz(3) + bone vector(3)
N_GLOBAL = 15 + 4 + 10 + 5 + 3 + 2           # angles, abduction, tip-tip, tip-wrist, normal, orientation
GLOBAL_WIDTH = 2 * N_GLOBAL                  # value + per-step delta channels, per hand
N_MOTION = 2 * 9 + 3                         # per hand (pos, anchored pos, vel, acc, speed) + two-hand relation
N_META = 6
VEL_SCALE, ACC_SCALE = 5.0, 50.0             # palm-lengths/s and /s^2 -> O(1)
MIN_PALM = 0.015                             # image-width units; smaller is degenerate


@dataclass(frozen=True)
class FeatureConfig:
    """Every flag is an ablation switch; the defaults are the candidate model."""
    steps: int = 32                # resampled length
    max_gap_ms: float = 150.0      # longest gap bridged by interpolation
    derivatives: bool = True       # velocity/acceleration (motion) + shape deltas
    motion: bool = True            # trajectory stream at all
    anchors: bool = True           # signer-relative coordinates when anchors exist
    rotate: bool = False           # in-plane rotation normalization of the hand shape
    angles: bool = True            # engineered angle/distance features
    canonical_dominant: bool = False   # mirror so the moving hand is the right hand

    def dims(self) -> dict:
        return {"steps": self.steps, "nodes": (2, N_JOINTS, NODE_C), "glob": (2, GLOBAL_WIDTH),
                "motion": N_MOTION, "mask": 3, "meta": N_META}


@dataclass
class RawSequence:
    """Aspect-corrected, mirror-canonical observations. slot 0 = Left, 1 = Right."""
    t_ms: np.ndarray                     # (N,) strictly increasing
    xyz: np.ndarray                      # (N, 2, 21, 3) float64
    present: np.ndarray                  # (N, 2) bool
    score: np.ndarray                    # (N, 2) handedness confidence
    anchor_xy: np.ndarray | None = None  # (N, 2) reference point (e.g. nose), aspect-corrected
    anchor_scale: np.ndarray | None = None  # (N,) e.g. shoulder width
    anchor_ok: np.ndarray | None = None     # (N,) bool

    @property
    def n(self) -> int:
        return len(self.t_ms)

    def copy(self) -> "RawSequence":
        return RawSequence(self.t_ms.copy(), self.xyz.copy(), self.present.copy(), self.score.copy(),
                           None if self.anchor_xy is None else self.anchor_xy.copy(),
                           None if self.anchor_scale is None else self.anchor_scale.copy(),
                           None if self.anchor_ok is None else self.anchor_ok.copy())


@dataclass
class Features:
    nodes: np.ndarray    # (T, 2, 21, 6)
    glob: np.ndarray     # (T, 2, G)
    motion: np.ndarray   # (T, M)
    mask: np.ndarray     # (T, 3): left, right, anchor
    meta: np.ndarray     # (K,)
    tracking_quality: float

    def flat(self) -> np.ndarray:
        t = self.nodes.shape[0]
        return np.concatenate([self.nodes.reshape(t, -1), self.glob.reshape(t, -1),
                               self.motion, self.mask], axis=1).astype(np.float32)


class FeatureError(ValueError):
    pass


# --------------------------------------------------------------------------- frames -> raw

def frames_to_raw(frames: list[dict]) -> RawSequence:
    """App/corpus frame dicts -> RawSequence. Same canonicalization as the shipped matcher:
    unmirrored input is reflected and handedness swapped, x and z scaled by image aspect."""
    if not frames:
        raise FeatureError("no frames")
    n = len(frames)
    t = np.array([f["timestampMS"] for f in frames], dtype=np.float64)
    if not np.all(np.isfinite(t)) or np.any(np.diff(t) <= 0):
        raise FeatureError("timestamps must be finite and strictly increasing")
    xyz = np.zeros((n, 2, N_JOINTS, 3))
    present = np.zeros((n, 2), dtype=bool)
    score = np.zeros((n, 2))
    anchor_xy = np.zeros((n, 2))
    anchor_scale = np.zeros(n)
    anchor_ok = np.zeros(n, dtype=bool)
    for i, frame in enumerate(frames):
        aspect = float(frame.get("imageAspectRatio") or 1.0)
        mirrored = frame.get("mirrored")
        mirrored = True if mirrored is None else bool(mirrored)
        if not math.isfinite(aspect) or not 0.1 <= aspect <= 10:
            raise FeatureError("bad aspect ratio")
        for hand in frame.get("hands", []):
            side = hand.get("handedness")
            if not mirrored:
                side = {"Left": "Right", "Right": "Left"}.get(side, side)
            if side not in ("Left", "Right") or len(hand.get("joints", [])) != N_JOINTS:
                continue
            slot = SLOT_LEFT if side == "Left" else SLOT_RIGHT
            s = float(hand.get("handednessScore", 0.5))
            s = min(1.0, max(0.0, s)) if math.isfinite(s) else 0.5
            pts = np.array([[(j["x"] if mirrored else 1 - j["x"]) * aspect, j["y"], j["z"] * aspect]
                            for j in hand["joints"]], dtype=np.float64)
            if not np.all(np.isfinite(pts)) or np.abs(pts).max() > 10:
                continue
            if np.linalg.norm(pts[9, :2] - pts[0, :2]) < MIN_PALM:
                continue
            if present[i, slot] and s <= score[i, slot]:
                continue  # duplicate same-side detection: keep the more confident one
            xyz[i, slot], present[i, slot], score[i, slot] = pts, True, s
        a = frame.get("anchor")
        if a and all(math.isfinite(float(a.get(k, math.nan))) for k in ("x", "y", "scale")) and a["scale"] > 0.02:
            ax = (a["x"] if mirrored else 1 - a["x"]) * aspect
            anchor_xy[i], anchor_scale[i], anchor_ok[i] = (ax, a["y"]), a["scale"] * aspect, True
    return RawSequence(t, xyz, present, score, anchor_xy if anchor_ok.any() else None,
                       anchor_scale if anchor_ok.any() else None, anchor_ok if anchor_ok.any() else None)


# --------------------------------------------------------------------------- resample

def _interp_slot(t_src, values, ok, t_tgt, max_gap):
    """Interpolate one slot's values (N, ...) at t_tgt using only observed neighbours.
    Returns (out, mask): mask 1 = between adjacent raw observations, 0.5 = bridged a short
    gap, 0 = missing (out zero)."""
    out = np.zeros((len(t_tgt),) + values.shape[1:])
    mask = np.zeros(len(t_tgt))
    idx = np.flatnonzero(ok)
    if len(idx) == 0:
        return out, mask
    ts = t_src[idx]
    for k, tau in enumerate(t_tgt):
        j = int(np.searchsorted(ts, tau))
        if j < len(ts) and abs(ts[j] - tau) < 1e-6:
            out[k], mask[k] = values[idx[j]], 1.0
            continue
        if j == 0 or j == len(ts):
            continue
        a, b = idx[j - 1], idx[j]
        span = t_src[b] - t_src[a]
        if span > max_gap:
            continue
        w = (tau - t_src[a]) / span
        out[k] = (1 - w) * values[a] + w * values[b]
        mask[k] = 1.0 if b == a + 1 else 0.5
    return out, mask


def resample(raw: RawSequence, cfg: FeatureConfig):
    """Uniform time grid across the attempt. Returns xyz (T,2,21,3), mask (T,2),
    score (T,2), anchor (T,3)=(x,y,scale), anchor_mask (T,), duration_ms."""
    if raw.n < 2:
        raise FeatureError("need at least two frames")
    T = cfg.steps
    t0, t1 = raw.t_ms[0], raw.t_ms[-1]
    grid = np.linspace(t0, t1, T)
    xyz = np.zeros((T, 2, N_JOINTS, 3))
    mask = np.zeros((T, 2))
    score = np.zeros((T, 2))
    for s in range(2):
        v, m = _interp_slot(raw.t_ms, raw.xyz[:, s].reshape(raw.n, -1), raw.present[:, s], grid, cfg.max_gap_ms)
        xyz[:, s] = v.reshape(T, N_JOINTS, 3)
        mask[:, s] = m
        sc, _ = _interp_slot(raw.t_ms, raw.score[:, s:s + 1], raw.present[:, s], grid, cfg.max_gap_ms)
        score[:, s] = sc[:, 0]
    anchor = np.zeros((T, 3))
    amask = np.zeros(T)
    if raw.anchor_xy is not None:
        vals = np.concatenate([raw.anchor_xy, raw.anchor_scale[:, None]], axis=1)
        anchor, amask = _interp_slot(raw.t_ms, vals, raw.anchor_ok, grid, cfg.max_gap_ms)
    return xyz, mask, score, anchor, amask, float(t1 - t0)


def mirror_raw(raw: RawSequence) -> RawSequence:
    """Reflect left<->right about x=0. Only valid where a sign has a mirror-equivalent
    execution (left-handed signers); used as canonicalization and as an ablated augmentation.
    Everything downstream is translation invariant, so the reflection axis is irrelevant."""
    out = raw.copy()
    out.xyz = raw.xyz[:, ::-1].copy()
    out.xyz[..., 0] = -out.xyz[..., 0]
    out.present = raw.present[:, ::-1].copy()
    out.score = raw.score[:, ::-1].copy()
    if out.anchor_xy is not None:
        out.anchor_xy[:, 0] = -out.anchor_xy[:, 0]
    return out


def dominant_slot(raw: RawSequence) -> int:
    """Hand with the larger wrist path length; ties go to Right."""
    path = []
    for s in range(2):
        idx = np.flatnonzero(raw.present[:, s])
        path.append(0.0 if len(idx) < 2 else float(np.linalg.norm(np.diff(raw.xyz[idx, s, 0, :2], axis=0), axis=1).sum()))
    return SLOT_LEFT if path[SLOT_LEFT] > path[SLOT_RIGHT] * 1.25 else SLOT_RIGHT


# --------------------------------------------------------------------------- per-frame geometry

def palm_scale(xyz: np.ndarray) -> np.ndarray:
    """(..., 21, 3) -> (...). Mean 3D wrist->MCP spoke length. Using four spokes instead
    of one 2D span keeps the scale stable when the palm foreshortens."""
    spokes = xyz[..., [5, 9, 13, 17], :] - xyz[..., 0:1, :]
    return np.linalg.norm(spokes, axis=-1).mean(axis=-1)


def _unit(v, eps=1e-9):
    return v / np.maximum(np.linalg.norm(v, axis=-1, keepdims=True), eps)


def _cos_angle(a, b, c):
    return (_unit(a - b) * _unit(c - b)).sum(-1)


def hand_geometry(rel: np.ndarray):
    """rel: (..., 21, 3) wrist-centred, palm-scaled. -> globals (..., G)."""
    angles = np.stack([_cos_angle(rel[..., a, :], rel[..., b, :], rel[..., c, :])
                       for a, b, c in ANGLE_TRIPLES], axis=-1)
    abd = np.stack([(_unit(rel[..., a, :]) * _unit(rel[..., b, :])).sum(-1) for a, b in ABDUCTION], axis=-1)
    tips = rel[..., list(FINGERTIPS), :]
    tt = np.stack([np.linalg.norm(tips[..., i, :] - tips[..., j, :], axis=-1)
                   for i in range(5) for j in range(i + 1, 5)], axis=-1)
    tw = np.linalg.norm(tips, axis=-1)
    normal = _unit(np.cross(rel[..., 5, :], rel[..., 17, :]))
    spoke = rel[..., 9, :2]
    ang = np.arctan2(spoke[..., 0], -spoke[..., 1])  # 0 when the fingers point up the image
    orient = np.stack([np.sin(ang), np.cos(ang)], axis=-1)
    return np.concatenate([angles, abd, tt, tw, normal, orient], axis=-1)


def _rotate_xy(rel: np.ndarray) -> np.ndarray:
    """Rotate about z so wrist->middle-MCP points to -y (image up). Orientation is not lost:
    it stays in the globals, which are computed before rotation."""
    v = rel[..., 9, :2]
    theta = np.arctan2(v[..., 0], -v[..., 1])
    c, s = np.cos(theta)[..., None], np.sin(theta)[..., None]
    out = rel.copy()
    x, y = rel[..., 0], rel[..., 1]
    out[..., 0] = c * x - s * y
    out[..., 1] = s * x + c * y
    return out


# --------------------------------------------------------------------------- featurize

def featurize(raw: RawSequence, cfg: FeatureConfig = FeatureConfig()) -> Features:
    if cfg.canonical_dominant and dominant_slot(raw) == SLOT_LEFT:
        raw = mirror_raw(raw)
    xyz, mask, score, anchor, amask, duration_ms = resample(raw, cfg)
    T = cfg.steps
    obs = mask > 0

    scale = np.where(obs, palm_scale(xyz), 0.0)                      # (T,2)
    safe = np.where(obs, np.maximum(scale, MIN_PALM), 1.0)
    wrist = xyz[:, :, 0, :]
    rel = (xyz - wrist[:, :, None, :]) / safe[:, :, None, None]
    rel = np.where(obs[:, :, None, None], rel, 0.0)

    glob = np.zeros((T, 2, N_GLOBAL))
    for s in range(2):
        if obs[:, s].any():
            glob[obs[:, s], s] = hand_geometry(rel[obs[:, s], s])
    shape_rel = _rotate_xy(rel) if cfg.rotate else rel
    bone = shape_rel - shape_rel[:, :, PARENT.clip(0), :]
    bone[:, :, 0, :] = 0
    nodes = np.concatenate([shape_rel, bone], axis=-1)
    nodes = np.where(obs[:, :, None, None], nodes, 0.0)
    if not cfg.angles:
        glob[..., :-5] = 0  # keep palm normal + orientation; drop engineered angles/distances

    if cfg.derivatives:
        # per-step change of shape: speed-normalized because the grid is duration-normalized
        both = obs[1:] & obs[:-1]
        dg = np.zeros_like(glob)
        dg[1:] = np.where(both[:, :, None], glob[1:] - glob[:-1], 0.0)
        glob = np.concatenate([glob, dg], axis=-1)
    else:
        glob = np.concatenate([glob, np.zeros_like(glob)], axis=-1)

    # ---- motion stream
    dt = max(duration_ms / 1000.0 / (T - 1), 1e-3)
    seq_scale = float(np.median(scale[obs])) if obs.any() else 1.0
    seq_scale = max(seq_scale, MIN_PALM)
    motion = np.zeros((T, N_MOTION))
    origin = np.zeros(2)
    first = np.flatnonzero(obs.any(axis=1))[:3]
    if len(first):
        pts = [wrist[i, s, :2] for i in first for s in range(2) if obs[i, s]]
        origin = np.mean(pts, axis=0)
    use_anchor = cfg.anchors and amask.max() > 0
    for s in range(2):
        base = s * 9
        pos = np.where(obs[:, s, None], (wrist[:, s, :2] - origin) / seq_scale, 0.0)
        motion[:, base:base + 2] = pos
        if use_anchor:
            ok = obs[:, s] & (amask > 0)
            rel_a = (wrist[:, s, :2] - anchor[:, :2]) / np.maximum(anchor[:, 2:3], 1e-3)
            motion[:, base + 2:base + 4] = np.where(ok[:, None], rel_a, 0.0)
        if cfg.derivatives:
            vel = np.zeros((T, 2))
            acc = np.zeros((T, 2))
            good = obs[:, s]
            for k in range(1, T - 1):
                if good[k - 1] and good[k + 1]:
                    vel[k] = (pos[k + 1] - pos[k - 1]) / (2 * dt)
            for k in range(1, T - 1):
                if good[k - 1] and good[k + 1] and good[k]:
                    acc[k] = (pos[k + 1] - 2 * pos[k] + pos[k - 1]) / (dt * dt)
            vel = np.clip(vel, -50, 50) / VEL_SCALE
            acc = np.clip(acc, -500, 500) / ACC_SCALE
            motion[:, base + 4:base + 6] = vel
            motion[:, base + 6:base + 8] = acc
            motion[:, base + 8] = np.linalg.norm(vel, axis=1)
    both = obs[:, 0] & obs[:, 1]
    rel_hands = np.where(both[:, None], (wrist[:, 1, :2] - wrist[:, 0, :2]) / seq_scale, 0.0)
    motion[:, 18:20] = rel_hands
    motion[:, 20] = np.linalg.norm(rel_hands, axis=1)
    if not cfg.motion:
        motion[:] = 0

    # ---- quality + meta
    expected = [s for s in range(2) if raw.present[:, s].mean() >= 0.3]
    if expected:
        cover = np.mean([(np.sum(mask[:, s] == 1.0) + 0.5 * np.sum(mask[:, s] == 0.5)) / T for s in expected])
        conf = np.mean([score[obs[:, s], s].mean() if obs[:, s].any() else 0.0 for s in expected])
        quality = float(cover * conf)
    else:
        quality = 0.0
    meta = np.array([math.log(max(duration_ms, 1.0) / 1000.0) + 0.5, quality,
                     float(obs[:, 0].mean()), float(obs[:, 1].mean()),
                     float(np.mean(mask == 0.5)), float(amask.mean() if use_anchor else 0.0)], dtype=np.float32)
    fmask = np.stack([mask[:, 0], mask[:, 1], amask if use_anchor else np.zeros(T)], axis=1)
    return Features(nodes.astype(np.float32), glob.astype(np.float32), motion.astype(np.float32),
                    fmask.astype(np.float32), meta, quality)


def featurize_frames(frames: list[dict], cfg: FeatureConfig = FeatureConfig()) -> Features:
    return featurize(frames_to_raw(frames), cfg)

