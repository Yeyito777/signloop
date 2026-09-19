"""Synthetic landmark sequences for TESTS AND PIPELINE CHECKS ONLY.

These are *not* ASL and their accuracy says nothing about sign recognition. The classes
are deliberately named S_* so they can never be mistaken for real vocabulary. They exist
so that feature code, models, splits, rejection, calibration, segmentation and replay can
be exercised end to end without any licensed data, including cases a real dataset makes
hard to isolate: signs that differ only by handshape or only by trajectory.
"""
from __future__ import annotations

from dataclasses import dataclass
import math

import numpy as np

ASPECT = 0.5625
FPS = 24.0
CLASSES = ["S_FLAT_STATIC", "S_FLAT_WAVE", "S_FIST_BOB", "S_POINT_CIRCLE", "S_Y_STATIC", "S_OPEN_CLOSE"]
NEG_KINDS = ["rest", "random_motion", "transition", "unsupported_shape", "incomplete", "incorrect"]

# ----------------------------------------------------------------------- hand model
_MCP = np.array([[-0.35, -1.00], [0.00, -1.05], [0.33, -0.98], [0.62, -0.85]])   # index..pinky
_SEG = np.array([[0.45, 0.30, 0.25], [0.50, 0.32, 0.26], [0.46, 0.30, 0.24], [0.36, 0.24, 0.20]])
_BEND = np.radians([80.0, 95.0, 60.0])
_THUMB_OPEN = np.array([[-0.35, -0.30], [-0.65, -0.55], [-0.85, -0.80], [-1.00, -1.00]])
_THUMB_FOLD = np.array([[-0.30, -0.30], [-0.15, -0.55], [0.05, -0.65], [0.20, -0.62]])


def hand_pose(curls: np.ndarray, thumb: float) -> np.ndarray:
    """curls (4,) 0=extended..1=curled for index..pinky; thumb 0=out..1=folded. -> (21,3)."""
    j = np.zeros((21, 3))
    t = (1 - thumb) * _THUMB_OPEN + thumb * _THUMB_FOLD
    j[1:5, :2] = t
    j[1:5, 2] = -0.1 * thumb * np.arange(1, 5) / 4
    for f in range(4):
        base = 5 + 4 * f
        pos = np.array([_MCP[f, 0], _MCP[f, 1], 0.0])
        j[base] = pos
        phi = 0.0
        for s in range(3):
            phi += curls[f] * _BEND[s]
            pos = pos + _SEG[f, s] * np.array([0.0, -math.cos(phi), -math.sin(phi)])
            j[base + 1 + s] = pos
    return j


def place(joints: np.ndarray, center: np.ndarray, size: float, roll: float, yaw: float) -> np.ndarray:
    c, s = math.cos(roll), math.sin(roll)
    cy, sy = math.cos(yaw), math.sin(yaw)
    x, y, z = joints[:, 0], joints[:, 1], joints[:, 2]
    x, z = cy * x + sy * z, -sy * x + cy * z
    x, y = c * x - s * y, s * x + c * y
    return np.stack([x * size + center[0], y * size + center[1], z * size], axis=1)


# ----------------------------------------------------------------------- signs
def _lerp(a, b, u):
    return (1 - u) * np.asarray(a, float) + u * np.asarray(b, float)


def sign_state(cls: str, u: float, amp: float):
    """Nominal hand state at normalized time u in [0,1]: curls, thumb, roll, yaw, offset (palm units)."""
    flat = (np.zeros(4), 0.0)
    fist = (np.ones(4) * 0.95, 0.9)
    if cls == "S_FLAT_STATIC":
        return *flat, 0.0, 0.0, np.zeros(2)
    if cls == "S_FLAT_WAVE":
        return *flat, 0.0, 0.0, np.array([amp * 2.2 * math.sin(2 * math.pi * 1.5 * u), 0.0])
    if cls == "S_FIST_BOB":
        return *fist, 0.0, 0.0, np.array([0.0, amp * 1.6 * math.sin(2 * math.pi * 2 * u)])
    if cls == "S_POINT_CIRCLE":
        curls = np.array([0.0, 0.95, 0.95, 0.95])
        a = 2 * math.pi * u
        return curls, 0.9, 0.0, 0.0, np.array([amp * 1.4 * math.cos(a), amp * 1.4 * math.sin(a)])
    if cls == "S_Y_STATIC":
        return np.array([0.95, 0.95, 0.95, 0.0]), 0.0, 0.0, 0.0, np.zeros(2)
    if cls == "S_OPEN_CLOSE":
        w = min(1.0, max(0.0, (u - 0.25) / 0.5))
        return _lerp(np.zeros(4), np.ones(4) * 0.95, w), 0.9 * w, 0.0, 0.0, np.zeros(2)
    raise KeyError(cls)


# (shape, trajectory) building blocks. The supported classes use six of the possible pairs; the
# "incorrect" negatives use pairs that are guaranteed NOT to coincide with any class.
SHAPES = {"flat": (np.zeros(4), 0.0), "fist": (np.ones(4) * 0.95, 0.9),
          "point": (np.array([0.0, 0.95, 0.95, 0.95]), 0.9), "Y": (np.array([0.95, 0.95, 0.95, 0.0]), 0.0)}
VALID_PAIRS = {("flat", "static"), ("flat", "wave"), ("fist", "bob"), ("point", "circle"), ("Y", "static")}
INCORRECT_COMBOS = [(sh, tr) for sh in SHAPES for tr in ("static", "wave", "bob", "circle")
                    if (sh, tr) not in VALID_PAIRS and tr != "static"]


def traj_offset(name: str, u: float, amp: float) -> np.ndarray:
    if name == "static":
        return np.zeros(2)
    if name == "wave":
        return np.array([amp * 2.2 * math.sin(2 * math.pi * 1.5 * u), 0.0])
    if name == "bob":
        return np.array([0.0, amp * 1.6 * math.sin(2 * math.pi * 2 * u)])
    if name == "circle":
        a = 2 * math.pi * u
        return np.array([amp * 1.4 * math.cos(a), amp * 1.4 * math.sin(a)])
    raise KeyError(name)


@dataclass
class Signer:
    id: str
    size: float          # palm length, image-width units
    speed: float         # >1 faster
    roll: float
    yaw: float
    jitter: float        # landmark noise, palm units
    drop: float          # per-frame hand-loss probability
    left_handed: bool
    style: float         # per-signer amplitude factor
    curl_bias: float
    base: np.ndarray
    device: str
    lighting: str

    @staticmethod
    def sample(rng: np.random.Generator, index: int) -> "Signer":
        return Signer(f"syn-signer-{index:03d}", float(rng.uniform(0.06, 0.11)), float(rng.uniform(0.75, 1.35)),
                      float(rng.normal(0, 0.10)), float(rng.normal(0, 0.15)), float(rng.uniform(0.005, 0.03)),
                      float(rng.uniform(0.0, 0.04)), bool(rng.random() < 0.12), float(rng.uniform(0.7, 1.3)),
                      float(rng.normal(0, 0.06)), np.array([rng.uniform(0.42, 0.58) * ASPECT, rng.uniform(0.48, 0.6)]),
                      str(rng.choice(["iphone-a", "iphone-b", "pixel-c"])), str(rng.choice(["bright", "dim", "mixed"])))


def _emit(states, signer: Signer, rng, t0_ms=0.0, hand_present=None):
    """states: list of (curls, thumb, roll, yaw, center_xy, size). -> frame dicts."""
    frames = []
    dt = 1000.0 / FPS
    dropout_left = 0
    for i, (curls, thumb, roll, yaw, center, size) in enumerate(states):
        present = True if hand_present is None else bool(hand_present[i])
        if signer.drop and rng.random() < signer.drop:
            dropout_left = int(rng.integers(1, 4))
        if dropout_left > 0:
            dropout_left -= 1
            present = False
        hands = []
        if present:
            j = place(hand_pose(curls, thumb), center, size, roll + signer.roll, yaw + signer.yaw)
            j += rng.normal(0, signer.jitter * size, j.shape)
            side = "Left" if signer.left_handed else "Right"
            xn = j[:, 0] / ASPECT
            if signer.left_handed:
                xn = xn  # coordinates are already in the mirrored frame the app reports
            hands = [{"handedness": side, "handednessScore": float(np.clip(rng.normal(0.93, 0.04), 0.5, 1)),
                      "joints": [{"x": float(a), "y": float(b), "z": float(c / ASPECT)}
                                 for a, b, c in zip(xn, j[:, 1], j[:, 2])]}]
        frames.append({"timestampMS": int(round(t0_ms + i * dt)), "hands": hands,
                       "imageAspectRatio": ASPECT, "mirrored": True})
    return frames


def _state(signer, cls, u, rng_bias):
    curls, thumb, roll, yaw, off = sign_state(cls, u, signer.style)
    curls = np.clip(curls + signer.curl_bias, 0, 1)
    if signer.left_handed:
        off = off * np.array([-1.0, 1.0])
    center = signer.base + off * signer.size
    return (curls, thumb, roll, yaw, center, signer.size)


def make_sign(cls: str, signer: Signer, rng, duration_s: float | None = None):
    dur = (duration_s or (1.2 + rng.uniform(-0.15, 0.3))) / signer.speed
    n = max(8, int(dur * FPS))
    states = [_state(signer, cls, i / (n - 1), None) for i in range(n)]
    return _emit(states, signer, rng)


def make_negative(kind: str, signer: Signer, rng):
    n = int(rng.uniform(1.0, 1.8) * FPS)
    if kind == "rest":
        curls = np.clip(rng.uniform(0.2, 0.5, 4), 0, 1)
        states = [(curls, 0.4, 0.0, 0.0, signer.base + np.array([0.0, 0.25]), signer.size)] * n
        return _emit(states, signer, rng)
    if kind == "random_motion":
        pos = signer.base.copy()
        vel = rng.normal(0, 0.01, 2)
        curls = rng.uniform(0, 1, 4)
        states = []
        for _ in range(n):
            vel = 0.9 * vel + rng.normal(0, 0.012, 2)
            pos = pos + vel
            curls = np.clip(curls + rng.normal(0, 0.05, 4), 0, 1)
            states.append((curls, 0.5, rng.normal(0, 0.05), 0.0, pos, signer.size))
        return _emit(states, signer, rng)
    if kind == "transition":  # hand sweeping in from the edge and stopping
        edge = np.array([1.15 * ASPECT, signer.base[1]])
        curls = rng.uniform(0.0, 0.6, 4)
        states = []
        for i in range(n):
            u = min(1.0, i / (0.7 * n))
            states.append((curls, 0.3, 0.0, 0.0, _lerp(edge, signer.base, 1 - (1 - u) ** 2), signer.size))
        present = [abs(s[4][0]) < 1.0 * ASPECT + 0.02 for s in states]
        return _emit(states, signer, rng, hand_present=present)
    if kind == "unsupported_shape":
        curls = rng.uniform(0.1, 0.9, 4)
        thumb = rng.uniform(0, 1)
        moving = rng.random() < 0.5
        states = []
        for i in range(n):
            off = np.array([0.0, 0.0]) if not moving else np.array([math.sin(i / n * 5) * 1.2, 0.0]) * signer.size
            states.append((curls, thumb, rng.normal(0, 0.03), 0.0, signer.base + off, signer.size))
        return _emit(states, signer, rng)
    if kind == "incomplete":
        cls = str(rng.choice(CLASSES))
        full = make_sign(cls, signer, rng)
        keep = max(6, int(len(full) * rng.uniform(0.15, 0.35)))
        return full[:keep]
    if kind == "incorrect":  # a real shape with a real trajectory, in a combination that is NOT a class
        shape, traj = INCORRECT_COMBOS[int(rng.integers(len(INCORRECT_COMBOS)))]
        curls, thumb = SHAPES[shape]
        n = int(rng.uniform(1.0, 1.6) * FPS)
        states = []
        for i in range(n):
            off = traj_offset(traj, i / (n - 1), signer.style)
            states.append((np.clip(curls + signer.curl_bias, 0, 1), thumb, 0.0, 0.0, signer.base + off * signer.size, signer.size))
        return _emit(states, signer, rng)
    raise KeyError(kind)


def make_corpus(n_signers=12, per_class=4, per_neg=2, seed=0, classes=CLASSES) -> dict:
    """Corpus in the repo's version-1 schema with extra metadata. Splits are assigned by
    signer elsewhere (recognition.data); here every sample is left un-split."""
    rng = np.random.default_rng(seed)
    samples = []
    for s in range(n_signers):
        signer = Signer.sample(rng, s)
        for cls in classes:
            for k in range(per_class):
                samples.append(_sample(f"{signer.id}-{cls}-{k}", cls, signer, make_sign(cls, signer, rng), "sign"))
        for kind in NEG_KINDS:
            for k in range(per_neg):
                samples.append(_sample(f"{signer.id}-neg-{kind}-{k}", "UNKNOWN", signer,
                                       make_negative(kind, signer, rng), kind))
    return {"version": 1, "dataset": "SYNTHETIC pipeline-check data, not ASL", "samples": samples}


def _sample(ident, label, signer: Signer, frames, kind):
    dur = frames[-1]["timestampMS"] - frames[0]["timestampMS"]
    return {"id": ident, "label": label, "signer": signer.id, "source": "synthetic generator (recognition.synthetic)",
            "license": "n/a-synthetic", "redistribution": "ALLOWED", "split": "train", "kind": kind,
            "session": f"{signer.id}-s0", "device": signer.device, "lighting": signer.lighting,
            "handedness": "Left" if signer.left_handed else "Right", "fps": FPS, "duration_ms": dur,
            "frames": frames}


def make_stream(signer: Signer, plan: list[tuple[str, str]], rng, gap_s=0.8):
    """Continuous recording: plan = [(kind, name)], kind in {'sign','neg','idle'}.
    Returns (frames, intervals[(start_ms, end_ms, label)]). Idle = no hand in view."""
    frames, intervals, t = [], [], 0.0
    for kind, name in plan:
        if kind == "idle":
            n = int(gap_s * FPS)
            piece = _emit([(np.zeros(4), 0, 0, 0, signer.base, signer.size)] * n, signer, rng, t, hand_present=[False] * n)
            label = None
        elif kind == "sign":
            piece, label = make_sign(name, signer, rng), name
        else:
            piece, label = make_negative(name, signer, rng), "UNKNOWN"
        base = t - piece[0]["timestampMS"]
        for f in piece:
            f["timestampMS"] = int(round(f["timestampMS"] + base))
        if frames and piece[0]["timestampMS"] <= frames[-1]["timestampMS"]:
            shift = frames[-1]["timestampMS"] - piece[0]["timestampMS"] + int(1000 / FPS)
            for f in piece:
                f["timestampMS"] += shift
        intervals.append((piece[0]["timestampMS"], piece[-1]["timestampMS"], label))
        frames.extend(piece)
        t = frames[-1]["timestampMS"] + 1000.0 / FPS
    return frames, intervals
