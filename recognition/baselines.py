"""The current in-repo recognizer, evaluated under the SAME split/metrics as the new engine.

"Current baseline" = reference-dtw-v2 (backend/matcher.py, ported and parity-tested in
ios/Signloop/TemporalReferenceMatcher.swift). It is the only landmark-based recognizer in the
repo that can be trained on our own corpus. The shipped ILY canned-gesture rule cannot be
compared (different vocabulary, single-frame, no landmark-sequence interface), and the
undistributed Kaggle weights are excluded by the rights constraint.

Thresholds follow the previous protocol (docs/recognition-evaluation.md): a fixed grid on the
validation signers, maximizing correct accepts subject to zero bad accepts. Test is read once.
"""
from __future__ import annotations

import math
import time

import numpy as np

from . import data as D
from .evaluate import decisions_report
from .openset import _feasible


def _ranked(matcher, samples):
    out = []
    ts = []
    for s in samples:
        t = time.perf_counter()
        ranked = matcher.rank(s["frames"])
        ts.append((time.perf_counter() - t) * 1000)
        out.append(ranked)
    return out, ts


def dtw_baseline(samples: list[dict], labels: D.Labels | None = None, far_high: float = 0.05) -> dict:
    from backend.matcher import TrackedReferenceMatcher
    labels = labels or D.Labels.from_samples([s for s in samples if s["split"] == "train"])
    legacy = []
    for s in samples:
        c = dict(s)
        c["split"] = "train" if s["split"] == "train" else "calibration" if s["split"] == "val" else "test"
        legacy.append(c)
    # Earlier protocol: training clips the matcher cannot use are excluded before matching.
    usable, dropped = [], 0
    for c in legacy:
        if c["split"] == "train" and c["label"] != D.UNKNOWN:
            if not TrackedReferenceMatcher.feature_function(c["frames"]):
                dropped += 1
                continue
        usable.append(c)
    legacy = usable
    matcher = TrackedReferenceMatcher(legacy, max_distance=0, min_margin=1)
    val = [s for s in legacy if s["split"] == "calibration"]
    test = [s for s in legacy if s["split"] == "test"]
    val_rank, _ = _ranked(matcher, val)
    test_rank, test_ms = _ranked(matcher, test)
    k = labels.k

    def decide(ranked, dist, margin):
        if not ranked:
            return k
        best, second = ranked[0], ranked[1] if len(ranked) > 1 else None
        m = (second["distance"] - best["distance"]) / max(second["distance"], 1e-9) if second else 1.0
        return labels.index(best["label"]) if best["distance"] <= dist and m >= margin else k

    truth_v = [labels.index(s["label"]) for s in val]
    # (a) legacy protocol: grid on validation, maximize correct accepts with ZERO bad accepts
    best_cfg, best_score = (0.0, 1.0), (-1, 0)
    for dist in [i * 0.05 for i in range(81)]:
        for margin in (0.0, 0.05, 0.1, 0.2, 0.3):
            preds = [decide(r, dist, margin) for r in val_rank]
            bad = sum(1 for p, t in zip(preds, truth_v) if p != k and p != t)
            good = sum(1 for p, t in zip(preds, truth_v) if p == t and t != k)
            if bad == 0 and (good, -dist) > best_score:
                best_cfg, best_score = (dist, margin), (good, -dist)
    dist, margin = best_cfg
    # (b) SAME rule as the new engine: score = -best DTW distance; smallest threshold whose
    # Wilson upper bound on the bad-accept rate is <= far_high on the validation signers.
    def nearest(ranked):
        return (labels.index(ranked[0]["label"]), -ranked[0]["distance"]) if ranked else (k, -np.inf)
    vn = [nearest(r) for r in val_rank]
    vscore = np.array([x[1] for x in vn])
    vpred = np.array([x[0] for x in vn])
    vy = np.array(truth_v)
    vunknown = vy == k
    vbad = (vpred != k) & ((vunknown) | (vpred != vy))
    ref_n = max(int(vunknown.sum() + (~vunknown & (vpred != vy)).sum()), 1)
    tau = _feasible(vscore, vbad, far_high, ref_n)
    truth = np.array([labels.index(s["label"]) for s in test])
    near_test = [nearest(r) for r in test_rank]
    near = np.array([x[0] for x in near_test])
    tscore = np.array([x[1] for x in near_test])
    pred_same = np.where(tscore >= tau, near, k)
    pred = np.array([decide(r, dist, margin) for r in test_rank])
    conf = np.array([math.exp(-r[0]["distance"]) if r else 0.0 for r in test_rank])
    tier_same = ["show" if p != k else "unknown" for p in pred_same]
    tier = ["show" if p != k else "unknown" for p in pred]
    legacy_rep = decisions_report(labels.names, truth, pred, conf, near == truth, tier, test)
    rep = decisions_report(labels.names, truth, pred_same, conf, near == truth, tier_same, test)
    rep["legacy_protocol"] = {"max_distance": dist, "min_margin": margin,
                              "known_top1_after_rejection": legacy_rep["known_top1_after_rejection"],
                              "false_accept_rate_show": legacy_rep["open_set"]["false_accept_rate_show"],
                              "coverage_show": legacy_rep["open_set"]["coverage_show"]}
    rep["same_policy_tau"] = None if tau == float("inf") else float(tau)
    rep["baseline"] = {"model": "reference-dtw-v2",
                       "unusable_observations": int(sum(1 for r in test_rank if not r)),
                       "unusable_train_references_dropped": dropped,
                       "latency_ms_python_p50": float(np.percentile(test_ms, 50)),
                       "latency_ms_python_p95": float(np.percentile(test_ms, 95)),
                       "note": "confidence is exp(-distance): a similarity, not a probability"}
    rep["provenance"] = D.provenance(samples)
    return rep
