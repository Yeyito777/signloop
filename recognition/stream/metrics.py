from __future__ import annotations

import numpy as np

KS = (1, 3, 5, 10)


def softmax(z, axis=-1):
    z = z - z.max(axis=axis, keepdims=True)
    e = np.exp(z)
    return e / e.sum(axis=axis, keepdims=True)


def topk_acc(p: np.ndarray, y_local: np.ndarray, ks=KS) -> dict:
    """p: (N, V) scores over the active vocabulary, y_local index of the truth in that vocabulary."""
    order = np.argsort(-p, axis=1)
    rank = np.argmax(order == y_local[:, None], axis=1)
    return {f"top{k}": float((rank < k).mean()) for k in ks} | {"n": int(len(y_local)), "mean_rank": float(rank.mean() + 1)}


def restrict(scores_full: np.ndarray, y_full: np.ndarray, vocab: np.ndarray):
    """Keep clips whose class is in `vocab`; return (scores over vocab, local labels)."""
    pos = -np.ones(scores_full.shape[1], dtype=int)
    pos[vocab] = np.arange(len(vocab))
    keep = pos[y_full] >= 0
    return scores_full[keep][:, vocab], pos[y_full[keep]], keep


def wilson(p: float, n: int, z: float = 1.96):
    if n == 0:
        return (0.0, 1.0)
    d = 1 + z * z / n
    c = p + z * z / (2 * n)
    r = z * np.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    return float((c - r) / d), float((c + r) / d)
