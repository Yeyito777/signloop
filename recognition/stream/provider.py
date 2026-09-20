"""Common provider boundary: every recognizer consumes a Window and emits top-k, never top-1 only."""
from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field

import numpy as np


@dataclass
class Window:
    """Shared representation for one temporal window. keypoints follow MediaPipe Holistic ordering
    without face: 33 pose + 21 left hand + 21 right hand = 75 points (x, y[, z]) in image-normalized
    coordinates. Richer streams (face, visibility, velocities) can ride along in `extra` and are not
    consumed by hand/body-only providers."""
    t0: float                       # seconds
    t1: float
    keypoints: np.ndarray           # (T, 75, 3)
    confidences: np.ndarray | None = None   # (T, 75)
    extra: dict = field(default_factory=dict)


@dataclass
class ProviderResult:
    provider: str
    t0: float
    t1: float
    predictions: list[tuple[str, float]]     # top-k (label, probability over the ACTIVE vocabulary)
    latency_ms: float
    vocab_size: int

    def to_json(self) -> dict:
        return {"timestamp_start": self.t0, "timestamp_end": self.t1, "provider": self.provider,
                "predictions": [{"label": l, "confidence": round(float(p), 4)} for l, p in self.predictions],
                "latency_ms": round(self.latency_ms, 1)}


class RecognitionProvider(ABC):
    name: str
    labels: list[str]

    @abstractmethod
    def probs(self, windows: list[Window], vocab: np.ndarray | None) -> np.ndarray:
        """(N, V) probabilities over `vocab` (indices into self.labels; None = all). Batched."""

    def infer(self, window: Window, vocab: np.ndarray | None = None, k: int = 10) -> ProviderResult:
        import time
        t = time.perf_counter()
        idx = vocab if vocab is not None else np.arange(len(self.labels))
        rows = np.asarray(self.probs([window], vocab), dtype=float)
        if (rows.shape != (1, len(idx)) or not np.isfinite(rows).all() or
                (rows < 0).any() or (rows > 1).any() or
                not np.isclose(rows.sum(), 1.0, atol=1e-4, rtol=0)):
            raise ValueError("provider must return a finite normalized (1, active_vocab) distribution")
        p = rows[0]
        ms = (time.perf_counter() - t) * 1000
        order = np.argsort(-p)[:k]
        return ProviderResult(self.name, window.t0, window.t1, [(self.labels[int(idx[i])], float(p[i])) for i in order],
                              ms, len(idx))

    @abstractmethod
    def info(self) -> dict:
        """Architecture, params, size, input format, license status. Used to build the docs tables."""
