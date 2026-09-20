"""Multi-provider fusion over per-window probability arrays. Each takes probs: list of (..., V)
arrays (one per provider, same shape) and returns fused (..., V) scores. Simple first; the
benchmark decides which is kept."""
from __future__ import annotations

import numpy as np


def mean_prob(ps, w=None):
    ps = np.stack(ps)
    w = np.ones(len(ps)) if w is None else np.asarray(w, float)
    return (ps * w.reshape(-1, *[1] * (ps.ndim - 1))).sum(0) / w.sum()


def geo_mean(ps, w=None):
    ps = np.log(np.clip(np.stack(ps), 1e-9, 1))
    w = np.ones(len(ps)) if w is None else np.asarray(w, float)
    z = (ps * w.reshape(-1, *[1] * (ps.ndim - 1))).sum(0) / w.sum()
    z = np.exp(z - z.max(-1, keepdims=True))
    return z / z.sum(-1, keepdims=True)


def majority_vote(ps, w=None):
    """Each provider votes for its top-1; ties and the remaining ranking are broken by mean probability."""
    ps = np.stack(ps)
    w = np.ones(len(ps)) if w is None else np.asarray(w, float)
    votes = np.zeros(ps.shape[1:])
    top = ps.argmax(-1)
    for i in range(len(ps)):
        np.add.at(votes, tuple(np.indices(top[i].shape)) + (top[i],) if top[i].ndim else (top[i],), w[i])
    return votes + 1e-3 * mean_prob(ps, w)


def reliability_weights(provider_probs, y, n_classes, prior=3.0):
    """Per-provider, per-class weights = shrunk precision of that provider's top-1 on a held-out fold.
    provider_probs: list of (N, V); y: (N,). Returns (P, V) weights in [0,1]."""
    W = []
    for p in provider_probs:
        pred = p.argmax(1)
        glob = float((pred == y).mean())
        wc = np.full(n_classes, glob)
        for c in range(n_classes):
            said = pred == c
            n = said.sum()
            wc[c] = ((said & (y == c)).sum() + prior * glob) / (n + prior)
        W.append(wc)
    return np.stack(W)


def class_reliability(ps, W, gamma=1.0):
    ps = np.stack(ps)
    fused = ps * (W.reshape(len(ps), *[1] * (ps.ndim - 2), -1) ** gamma)
    return fused.mean(0)
