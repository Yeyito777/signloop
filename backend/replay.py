"""Reproducible signer-disjoint evaluation. Never tune on the test split."""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import time

from .matcher import ReferenceMatcher, load_corpus


def metrics(rows, matcher):
    confusion = Counter()
    known = correct = unknown = false_accept = accepted = correct_accepted = 0
    nearest_correct = unusable = 0
    for sample, ranked in rows:
        result = matcher.decide(ranked)
        prediction = "UNKNOWN" if result["unknown"] else ranked[0]["label"]
        truth = sample["label"]
        confusion[(truth, prediction)] += 1
        if truth == "UNKNOWN":
            unknown += 1
            false_accept += prediction != "UNKNOWN"
        else:
            known += 1
            correct += prediction == truth
            nearest_correct += bool(ranked) and ranked[0]["label"] == truth
        unusable += not bool(ranked)
        accepted += prediction != "UNKNOWN"
        correct_accepted += prediction == truth and truth != "UNKNOWN"
    return {"samples": len(rows), "known_samples": known, "unknown_samples": unknown,
            "known_accuracy": correct / known if known else None,
            "known_top1_before_rejection": nearest_correct / known if known else None,
            "unusable_observations": unusable,
            "unknown_false_accept_rate": false_accept / unknown if unknown else None,
            "accepted_precision": correct_accepted / accepted if accepted else None,
            "coverage": accepted / len(rows) if rows else 0,
            "confusion": [{"truth": a, "predicted": b, "count": n}
                          for (a, b), n in sorted(confusion.items())]}


def evaluate(corpus, corpus_sha):
    samples = corpus["samples"]
    matcher = ReferenceMatcher(samples, max_distance=0, min_margin=1)
    by_split = {split: [s for s in samples if s["split"] == split]
                for split in ("train", "calibration", "test")}
    for split in ("calibration", "test"):
        labels = {s["label"] for s in by_split[split]}
        if not set(matcher.labels) | {"UNKNOWN"} <= labels:
            raise ValueError(f"{split} needs every supported label and UNKNOWN negatives.")
    # Precompute expensive distances once. Test remains unread until selection.
    start = time.perf_counter()
    calibration = [(s, matcher.rank(s["frames"])) for s in by_split["calibration"]]
    # Fixed grid avoids selecting thresholds on individual floating-point
    # distances. No test-dependent choices, including grid/feature changes.
    thresholds = [i * .05 for i in range(81)]
    best, chosen = None, None
    for threshold in thresholds:
        for margin in (0.05, .1, .15, .2, .3, .4):
            matcher.max_distance, matcher.min_margin = threshold, margin
            scores = metrics(calibration, matcher)
            # Require zero calibration false positives on unsupported signs.
            # This is a small-sample operating point, NOT a safety guarantee.
            if scores["unknown_false_accept_rate"] != 0:
                continue
            objective = (scores["known_accuracy"], scores["accepted_precision"] or 0,
                         -threshold, margin)
            if best is None or objective > best:
                best, chosen = objective, (threshold, margin)
    if chosen is None:
        raise ValueError("No calibration operating point.")
    matcher.max_distance, matcher.min_margin = chosen
    selection_seconds = time.perf_counter() - start
    start = time.perf_counter()
    test = [(s, matcher.rank(s["frames"])) for s in by_split["test"]]
    test_seconds = time.perf_counter() - start
    return {
        "model": "reference-dtw-v1", "corpus_sha256": corpus_sha,
        "scope": "Isolated public research clips, NOT iPhone/live/continuous-sign validation.",
        "dataset": corpus.get("dataset"), "signer_disjoint": True,
        "parameters": {"max_distance": chosen[0], "min_margin": chosen[1]},
        "split_counts": {k: len(v) for k, v in by_split.items()},
        "signer_counts": {k: len({s["signer"] for s in v}) for k, v in by_split.items()},
        "calibration": metrics(calibration, matcher), "test": metrics(test, matcher),
        "timing": {"calibration_seconds": selection_seconds,
                   "test_mean_ms": 1000 * test_seconds / len(test)},
        "test_predictions": [
            {"id": s["id"], "truth": s["label"], **matcher.decide(r)} for s, r in test],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("corpus", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    corpus = load_corpus(args.corpus)
    report = evaluate(corpus, hashlib.sha256(args.corpus.read_bytes()).hexdigest())
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    print(json.dumps({k: v for k, v in report.items() if k != "test_predictions"}, indent=2))


if __name__ == "__main__":
    main()
