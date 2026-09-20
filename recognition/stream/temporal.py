"""Overlapping windows, temporal aggregation, and the deterministic evidence resolver.

States (never a forced answer):
  unknown    evidence too weak to show anything
  tentative  displayable but revisable: top hypothesis above tau_t
  stable     same top-1 for >= n_stable consecutive updates, smoothed confidence >= tau_s and margin >= margin
  committed  stable for >= n_commit updates (or the stream ended while stable)
A later window with different evidence moves the state back down; nothing is latched.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np


def make_windows(duration_s: float, width: float, stride: float) -> list[tuple[float, float]]:
    """Overlapping [t0, t1) windows. The last window always ends at the stream end so the final
    evidence is never dropped. A stream shorter than one window yields one (shorter) window."""
    if duration_s <= width:
        return [(0.0, duration_s)]
    out, t = [], 0.0
    while t + width <= duration_s + 1e-9:
        out.append((round(t, 4), round(t + width, 4)))
        t += stride
    if out[-1][1] < duration_s - 1e-6:
        out.append((round(duration_s - width, 4), duration_s))
    return out


# ---- aggregation of per-window probability rows P (n, V) -> score over V
def agg_mean(P):
    return P.mean(0)


def agg_geo(P):
    return np.exp(np.log(np.clip(P, 1e-9, 1)).mean(0))


def agg_max(P):
    return P.max(0)


def agg_recency(P, decay=0.7):
    w = decay ** np.arange(len(P))[::-1]
    return (P * w[:, None]).sum(0) / w.sum()


def agg_center(P):
    """Weights windows by closeness to the middle of the stream (the sign is usually mid-clip)."""
    n = len(P)
    w = np.exp(-0.5 * ((np.arange(n) - (n - 1) / 2) / max(n / 4, 1e-6)) ** 2)
    return (P * w[:, None]).sum(0) / w.sum()


AGG = {"mean": agg_mean, "geo": agg_geo, "max": agg_max, "recency": agg_recency, "center": agg_center}


@dataclass(frozen=True)
class ResolverConfig:
    decay: float = 0.6        # evidence EMA: e = decay*e + (1-decay)*p
    tau_t: float = 0.20       # tentative threshold on smoothed top probability
    tau_s: float = 0.35       # stable threshold
    margin: float = 0.10      # top1 - top2 for stable
    n_stable: int = 2
    n_commit: int = 3
    tau_u: float = 0.08       # below this: unknown


class TemporalResolver:
    def __init__(self, cfg: ResolverConfig = ResolverConfig()):
        self.cfg = cfg
        self.reset()

    def reset(self):
        self.e = None
        self.run = 0
        self.last_top = None
        self.steps = 0

    def step(self, p: np.ndarray) -> dict:
        c = self.cfg
        self.e = p.copy() if self.e is None else c.decay * self.e + (1 - c.decay) * p
        order = np.argsort(-self.e)[:5]
        top, second = int(order[0]), float(self.e[order[1]]) if len(order) > 1 else 0.0
        conf, margin = float(self.e[top]), float(self.e[top]) - second
        self.run = self.run + 1 if top == self.last_top else 1
        self.last_top = top
        self.steps += 1
        if conf < c.tau_u:
            state = "unknown"
        elif conf >= c.tau_s and margin >= c.margin and self.run >= c.n_stable:
            state = "committed" if self.run >= c.n_commit else "stable"
        elif conf >= c.tau_t:
            state = "tentative"
        else:
            state = "unknown"
        return {"state": state, "top": [(int(i), float(self.e[i])) for i in order], "confidence": conf, "margin": margin,
                "run": self.run, "step": self.steps}


def run_stream(P_seq: np.ndarray, cfg: ResolverConfig = ResolverConfig()):
    """Feed a (n_windows, V) sequence; -> list of per-step states."""
    r = TemporalResolver(cfg)
    return [r.step(p) for p in P_seq]
