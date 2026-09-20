"""Disk cache of raw provider logits so every downstream experiment (vocab scaling, fusion, temporal,
context) reads the SAME real inference outputs. Logits are float16; nothing is regenerated silently."""
from __future__ import annotations

from pathlib import Path
import time

import numpy as np

CACHE = Path(__file__).resolve().parents[2] / ".runtime" / "stream"


def _path(provider: str, key: str) -> Path:
    CACHE.mkdir(parents=True, exist_ok=True)
    return CACHE / f"{provider}__{key}.npz"


def get_logits(provider, key: str, windows_fn, force=False):
    """-> (logits float32 (N,V), seconds_total). windows_fn() builds the Window list lazily."""
    p = _path(provider.name, key)
    if p.exists() and not force:
        d = np.load(p)
        return d["logits"].astype(np.float32), float(d["seconds"])
    windows = windows_fn()
    t = time.perf_counter()
    z = provider.logits(windows)
    dt = time.perf_counter() - t
    np.savez(p, logits=z.astype(np.float16), seconds=dt, n=len(windows))
    return z, dt
