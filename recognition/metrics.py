"""Classification, calibration and open-set metrics. numpy only, no sklearn dependency."""
from __future__ import annotations

import math

import numpy as np


def softmax(logits: np.ndarray, temperature: float = 1.0) -> np.ndarray:
    z = np.asarray(logits, dtype=np.float64) / temperature
    z = z - z.max(axis=-1, keepdims=True)
    e = np.exp(z)
    return e / e.sum(axis=-1, keepdims=True)


def confusion(y_true, y_pred, n: int) -> np.ndarray:
    m = np.zeros((n, n), dtype=np.int64)
    for t, p in zip(y_true, y_pred):
        m[t, p] += 1
    return m


def classification_report(y_true, y_pred, names: list[str]) -> dict:
    """names includes UNKNOWN as the last entry. Macro metrics are over classes with support
    so an absent class does not silently count as F1 = 0."""
    n = len(names)
    cm = confusion(y_true, y_pred, n)
    tp = np.diag(cm).astype(float)
    support = cm.sum(1)
    pred_n = cm.sum(0)
    prec = np.divide(tp, pred_n, out=np.full(n, np.nan), where=pred_n > 0)
    rec = np.divide(tp, support, out=np.full(n, np.nan), where=support > 0)
    f1 = np.where((prec + rec) > 0, 2 * prec * rec / np.where((prec + rec) > 0, prec + rec, 1), 0.0)
    has = support > 0
    return {"accuracy": float(tp.sum() / max(cm.sum(), 1)),
            "macro_f1": float(np.nanmean(np.where(has, f1, np.nan))) if has.any() else float("nan"),
            "balanced_accuracy": float(np.nanmean(np.where(has, rec, np.nan))) if has.any() else float("nan"),
            "per_class": {names[i]: {"precision": None if np.isnan(prec[i]) else float(prec[i]),
                                     "recall": None if np.isnan(rec[i]) else float(rec[i]),
                                     "f1": float(f1[i]), "support": int(support[i])} for i in range(n)},
            "confusion": cm.tolist(), "labels": names}


def ece(conf, correct, bins: int = 15) -> float:
    conf, correct = np.asarray(conf, float), np.asarray(correct, float)
    if len(conf) == 0:
        return float("nan")
    edges = np.linspace(0, 1, bins + 1)
    idx = np.clip(np.digitize(conf, edges[1:-1]), 0, bins - 1)
    total = 0.0
    for b in range(bins):
        m = idx == b
        if m.any():
            total += m.mean() * abs(correct[m].mean() - conf[m].mean())
    return float(total)


def reliability(conf, correct, bins: int = 10) -> list[dict]:
    conf, correct = np.asarray(conf, float), np.asarray(correct, float)
    edges = np.linspace(0, 1, bins + 1)
    idx = np.clip(np.digitize(conf, edges[1:-1]), 0, bins - 1)
    out = []
    for b in range(bins):
        m = idx == b
        out.append({"lo": float(edges[b]), "hi": float(edges[b + 1]), "n": int(m.sum()),
                    "confidence": float(conf[m].mean()) if m.any() else None,
                    "accuracy": float(correct[m].mean()) if m.any() else None})
    return out


def coverage_accuracy(conf, correct, points: int = 21) -> list[dict]:
    """Accuracy of the retained subset as the confidence cut rises."""
    conf, correct = np.asarray(conf, float), np.asarray(correct, float)
    out = []
    for tau in np.unique(np.quantile(conf, np.linspace(0, 0.98, points))) if len(conf) else []:
        m = conf >= tau
        out.append({"threshold": float(tau), "coverage": float(m.mean()), "accuracy": float(correct[m].mean())})
    return out


def auroc(pos, neg) -> float:
    """P(score_pos > score_neg), ties count half. Positives = the samples that should be accepted."""
    pos, neg = np.asarray(pos, float), np.asarray(neg, float)
    if len(pos) == 0 or len(neg) == 0:
        return float("nan")
    allv = np.concatenate([pos, neg])
    order = allv.argsort(kind="mergesort")
    ranks = np.empty(len(allv))
    sorted_v = allv[order]
    i = 0
    while i < len(allv):
        j = i
        while j + 1 < len(allv) and sorted_v[j + 1] == sorted_v[i]:
            j += 1
        ranks[order[i:j + 1]] = (i + j) / 2 + 1
        i = j + 1
    return float((ranks[:len(pos)].sum() - len(pos) * (len(pos) + 1) / 2) / (len(pos) * len(neg)))


def wilson_upper(k: int, n: int, z: float = 1.96) -> float:
    if n == 0:
        return 1.0
    p = k / n
    d = 1 + z * z / n
    c = p + z * z / (2 * n)
    r = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    return min(1.0, (c + r) / d)


def fit_temperature(logits, y) -> float:
    """Single scalar T minimizing validation NLL (log-grid, then refinement)."""
    logits, y = np.asarray(logits, float), np.asarray(y)
    if len(y) == 0:
        return 1.0

    def nll(t):
        z = logits / t
        z = z - z.max(1, keepdims=True)
        return float(-(z[np.arange(len(y)), y] - np.log(np.exp(z).sum(1))).mean())

    grid = np.exp(np.linspace(math.log(0.25), math.log(8), 60))
    best = grid[int(np.argmin([nll(t) for t in grid]))]
    fine = np.linspace(best / 1.15, best * 1.15, 40)
    return float(fine[int(np.argmin([nll(t) for t in fine]))])


def per_group(y_true, y_pred, groups) -> dict:
    out = {}
    for g in sorted(set(groups)):
        m = np.array([x == g for x in groups])
        out[str(g)] = {"n": int(m.sum()), "accuracy": float((np.asarray(y_true)[m] == np.asarray(y_pred)[m]).mean())}
    return out
