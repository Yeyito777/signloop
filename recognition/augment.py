"""Landmark-space augmentation. Every transform is independently switchable so each can
be ablated on held-out signers; nothing here is on by default without evidence.

All transforms act on RawSequence (before features are recomputed). None fabricate a hand
that was not observed: dropout only removes observations, time warping only re-times them.
"""
from __future__ import annotations

from dataclasses import dataclass, replace
import math

import numpy as np

from .features import N_JOINTS, RawSequence, mirror_raw, palm_scale


@dataclass(frozen=True)
class AugmentConfig:
    p: float = 0.8                   # probability that any given enabled transform fires
    similarity: bool = True          # camera distance/translation (hands + anchor together)
    scale_range: float = 0.35        # +-fraction
    viewpoint: bool = True           # small 3D rotation of the hand(s)
    viewpoint_deg: float = 15.0
    roll: bool = True                # in-plane rotation of the whole scene
    roll_deg: float = 12.0
    time_warp: bool = True           # global speed + smooth non-uniform warp
    speed_range: float = 0.3
    temporal_crop: bool = True       # boundary slack from imperfect segmentation
    crop_frac: float = 0.12
    temporal_pad: bool = True
    pad_frac: float = 0.12
    jitter: bool = True              # tracker jitter, in palm units
    jitter_sigma: float = 0.03
    landmark_dropout: bool = True    # burst hand loss
    dropout_rate: float = 0.06
    frame_drop: bool = True
    frame_drop_rate: float = 0.1
    joint_outliers: bool = True      # a few joints jump for a few frames
    outlier_rate: float = 0.03
    anchor_dropout: bool = True
    anchor_dropout_p: float = 0.5
    mirror: bool = False             # only if the vocabulary is mirror-equivalent


NONE = AugmentConfig(p=0, similarity=False, viewpoint=False, roll=False, time_warp=False, temporal_crop=False,
                     temporal_pad=False, jitter=False, landmark_dropout=False, frame_drop=False,
                     joint_outliers=False, anchor_dropout=False)


def _rot3(rng, deg):
    a = np.radians(rng.uniform(-deg, deg, 3))
    cx, cy, cz = np.cos(a)
    sx, sy, sz = np.sin(a)
    rx = np.array([[1, 0, 0], [0, cx, -sx], [0, sx, cx]])
    ry = np.array([[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]])
    rz = np.array([[cz, -sz, 0], [sz, cz, 0], [0, 0, 1]])
    return rz @ ry @ rx


def augment(raw: RawSequence, cfg: AugmentConfig, rng: np.random.Generator) -> RawSequence:
    r = raw.copy()
    fire = lambda flag: flag and rng.random() < cfg.p
    if fire(cfg.mirror) and rng.random() < 0.5:
        r = mirror_raw(r)
    if fire(cfg.similarity):
        s = 1 + rng.uniform(-cfg.scale_range, cfg.scale_range)
        shift = rng.uniform(-0.15, 0.15, 2)
        r.xyz[..., :2] = r.xyz[..., :2] * s + shift
        r.xyz[..., 2] *= s
        if r.anchor_xy is not None:
            r.anchor_xy = r.anchor_xy * s + shift
            r.anchor_scale = r.anchor_scale * s
    if fire(cfg.viewpoint):
        R = _rot3(rng, cfg.viewpoint_deg)
        for s in range(2):
            if not r.present[:, s].any():
                continue
            c = r.xyz[r.present[:, s], s].reshape(-1, 3).mean(axis=0)
            r.xyz[:, s] = (r.xyz[:, s] - c) @ R.T + c
    if fire(cfg.roll):
        th = math.radians(rng.uniform(-cfg.roll_deg, cfg.roll_deg))
        R = np.array([[math.cos(th), -math.sin(th)], [math.sin(th), math.cos(th)]])
        pts = r.xyz[r.present]
        c = pts.reshape(-1, 3)[:, :2].mean(axis=0) if pts.size else np.zeros(2)
        r.xyz[..., :2] = (r.xyz[..., :2] - c) @ R.T + c
        if r.anchor_xy is not None:
            r.anchor_xy = (r.anchor_xy - c) @ R.T + c
    if fire(cfg.jitter):
        sigma = rng.uniform(0, cfg.jitter_sigma)
        scale = np.where(r.present, palm_scale(r.xyz), 0)[:, :, None, None]
        r.xyz += rng.normal(0, 1, r.xyz.shape) * sigma * scale
    if fire(cfg.joint_outliers) and r.present.any():
        scale = np.where(r.present, palm_scale(r.xyz), 0)
        for i, s in zip(*np.nonzero(r.present)):
            if rng.random() < cfg.outlier_rate:
                j = rng.integers(0, N_JOINTS, size=int(rng.integers(1, 3)))
                r.xyz[i, s, j] += rng.normal(0, 0.6, (len(j), 3)) * scale[i, s]
    if fire(cfg.landmark_dropout):
        i = 0
        while i < r.n:
            if rng.random() < cfg.dropout_rate:
                span = int(rng.integers(1, 5))
                slot = rng.choice([0, 1, 2])  # left, right, or both
                cols = [0, 1] if slot == 2 else [int(slot)]
                r.present[i:i + span, cols] = False
                i += span
            i += 1
    if fire(cfg.anchor_dropout) and r.anchor_ok is not None and rng.random() < cfg.anchor_dropout_p:
        r.anchor_ok[:] = False
        r.anchor_xy = r.anchor_scale = r.anchor_ok = None
    if fire(cfg.frame_drop) and r.n > 8:
        keep = rng.random(r.n) > cfg.frame_drop_rate
        keep[[0, -1]] = True
        r = _select(r, np.flatnonzero(keep))
    if fire(cfg.temporal_crop) and r.n > 12:
        a = int(r.n * rng.uniform(0, cfg.crop_frac))
        b = r.n - int(r.n * rng.uniform(0, cfg.crop_frac))
        if b - a >= 8:
            r = _select(r, np.arange(a, b))
    if fire(cfg.temporal_pad):
        r = _pad(r, rng, cfg.pad_frac)
    if fire(cfg.time_warp):
        r = _warp(r, rng, cfg.speed_range)
    return r


def _select(r: RawSequence, idx) -> RawSequence:
    return RawSequence(r.t_ms[idx], r.xyz[idx], r.present[idx], r.score[idx],
                       None if r.anchor_xy is None else r.anchor_xy[idx],
                       None if r.anchor_scale is None else r.anchor_scale[idx],
                       None if r.anchor_ok is None else r.anchor_ok[idx])


def _pad(r: RawSequence, rng, frac) -> RawSequence:
    """Hold the first/last observed pose for a short time. Simulates a segmenter that
    starts a little early / ends a little late; the held frames are copies, flagged as
    real observations, so this teaches boundary tolerance, not invented motion."""
    dt = float(np.median(np.diff(r.t_ms)))
    n0, n1 = int(r.n * rng.uniform(0, frac)), int(r.n * rng.uniform(0, frac))
    if n0 == n1 == 0:
        return r
    head = [0] * n0
    tail = [r.n - 1] * n1
    idx = np.array(head + list(range(r.n)) + tail)
    out = _select(r, idx)
    out.t_ms = np.concatenate([r.t_ms[0] - dt * np.arange(n0, 0, -1), r.t_ms, r.t_ms[-1] + dt * np.arange(1, n1 + 1)])
    return out


def _warp(r: RawSequence, rng, speed_range) -> RawSequence:
    t0, d = r.t_ms[0], r.t_ms[-1] - r.t_ms[0]
    speed = 1 + rng.uniform(-speed_range, speed_range)
    u = (r.t_ms - t0) / max(d, 1)
    a, b = rng.uniform(-0.25, 0.25, 2)
    w = u + a * np.sin(math.pi * u) + b * np.sin(2 * math.pi * u) / 2   # monotone for |a|+|b| small
    w = np.maximum.accumulate(np.clip(w, 0, 1))
    out = r.copy()
    t = t0 + w * d / speed
    for i in range(1, len(t)):
        if t[i] <= t[i - 1]:
            t[i] = t[i - 1] + 1e-3
    out.t_ms = t
    return out
