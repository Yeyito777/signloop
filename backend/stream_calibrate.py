"""Calibrate fixed 250ms rolling-window rejection using calibration data only.

Both unsupported false accepts and wrong-known displayed labels are constrained.
Not a production safety guarantee. Small calibration cohorts can still overfit.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from .matcher import MATCHERS, load_corpus
from .stream_replay import DisplayFilter, replay_clip, summarize

PHASES = (0, 83, 166)
INTERVAL_MS = 250
WINDOW_MS = 1200


def prepare(samples, matcher):
    """Compute each causal window's distances once, before threshold search."""
    prepared = []
    for sample in samples:
        cache = {}
        for phase in PHASES:
            rankings = []
            def classify(window):
                key = tuple(f["timestampMS"] for f in window)
                if key not in cache:
                    cache[key] = matcher.rank(window)
                rankings.append(cache[key])
                # Scheduling never depends on classification; no-hand frames do.
                return {"unknown": True, "candidates": []}
            run = replay_clip(sample["frames"], classify, interval_ms=INTERVAL_MS,
                              window_ms=WINDOW_MS, phase_ms=phase)
            ranks = iter(rankings)
            events = [{"t_ms": e["t_ms"], "reset": e["reset"],
                       **({} if e["reset"] else {"ranked": next(ranks)})} for e in run["events"]]
            prepared.append({"id": sample["id"], "truth": sample["label"],
                             "phase_ms": phase, "events": events})
    return prepared


def decide_runs(prepared, matcher):
    runs = []
    for trial in prepared:
        state, visible = DisplayFilter(), None
        events, onsets, raw = [], [], []
        for event in trial["events"]:
            if event["reset"]:
                state.reset()
                visible = None
                events.append({**event, "expected": None})
                continue
            result = matcher.decide(event["ranked"])
            label = None if result["unknown"] else result["candidates"][0]["label"]
            raw.append(label)
            next_visible = state.update(label)
            if next_visible is not None and next_visible != visible:
                onsets.append({"label": next_visible, "t_ms": event["t_ms"]})
            visible = next_visible
            events.append({"reset": False, "t_ms": event["t_ms"], "label": label, "expected": visible})
        runs.append({**trial, "events": events, "onsets": onsets, "raw_labels": raw, "requests": len(raw)})
    return runs


def choose(prepared, matcher):
    """Fixed grid; no test access. Reject-all is an explicit possible result."""
    best, chosen = None, None
    for threshold in (i*.05 for i in range(81)):
        for margin in (.05, .1, .15, .2, .3, .4):
            matcher.max_distance, matcher.min_margin = threshold, margin
            scores = summarize(decide_runs(prepared, matcher))
            if scores["wrong_visible_runs"]:
                continue
            objective = (scores["correct_visible_runs"], -threshold, margin)
            if best is None or objective > best:
                best, chosen = objective, (threshold, margin)
    if chosen is None:
        raise ValueError("No zero-displayed-error calibration operating point.")
    matcher.max_distance, matcher.min_margin = chosen
    return chosen


def evaluate(corpus, digest, model):
    matcher = MATCHERS[model](corpus["samples"], max_distance=0, min_margin=1)
    splits = {k: [s for s in corpus["samples"] if s["split"] == k]
              for k in ("calibration", "test")}
    for name, samples in splits.items():
        if not (set(matcher.labels) | {"UNKNOWN"}) <= {s["label"] for s in samples}:
            raise ValueError(f"{name} requires all supported labels and UNKNOWN.")
    calibration = prepare(splits["calibration"], matcher)
    chosen = choose(calibration, matcher)
    # Test geometry is not consumed until the operating point is frozen.
    calibration_runs = decide_runs(calibration, matcher)
    test_runs = decide_runs(prepare(splits["test"], matcher), matcher)
    return {
        "protocol": "rolling-calibration-v1", "model": model, "corpus_sha256": digest,
        "scope": "Development diagnostic on previously inspected test clips; NOT fresh accuracy.",
        "parameters": {"max_distance": chosen[0], "min_margin": chosen[1]},
        "stream": {"window_ms": WINDOW_MS, "interval_ms": INTERVAL_MS, "phases_ms": PHASES,
                   "confirmation_results": 2, "simulated_response_delay_ms": 0},
        "calibration_objective": "Maximize correct displayed runs with zero wrong displayed runs, "
                                 "including wrong-known labels AND unsupported false accepts.",
        "distinct_clips": {k: len(v) for k, v in splits.items()},
        "distinct_signers": {k: len({s["signer"] for s in v}) for k, v in splits.items()},
        "calibration": summarize(calibration_runs), "test": summarize(test_runs),
        "runs": test_runs,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("corpus", type=Path)
    parser.add_argument("--model", choices=("reference-dtw-v2", "reference-dtw-v3-mirror"),
                        default="reference-dtw-v2")
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    corpus = load_corpus(args.corpus)
    report = evaluate(corpus, hashlib.sha256(args.corpus.read_bytes()).hexdigest(), args.model)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    print(json.dumps({k: v for k, v in report.items() if k != "runs"}, indent=2))


if __name__ == "__main__":
    main()
