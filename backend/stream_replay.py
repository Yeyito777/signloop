"""Local rolling-window diagnostic, NOT continuous-sign or phone validation.

Uses frozen corpus-bound matcher thresholds. No training, network, provider,
video decoding, or threshold search. Clip labels do not supply sign onset times.
"""
from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import statistics

from .matcher import load_corpus
from .server import reference_service


class DisplayFilter:
    """Mirror Swift LiveSignFilter; verified separately by native replay."""
    def __init__(self):
        self.reset()

    def reset(self):
        self.pending = None
        self.count = 0

    def update(self, label):
        if label is None:
            self.reset()
            return None
        self.count = self.count + 1 if label == self.pending else 1
        self.pending = label
        return label if self.count >= 2 else None


def replay_clip(frames, classify, *, window_ms=1200, interval_ms=1000, phase_ms=0):
    """Replay observed frames with immediate responses and an initially empty buffer.

    Latest frame determines the window cutoff, as in CameraTracker.recentFrames.
    Every no-hand camera frame clears pending/visible state, including between
    requests. Snap poll times forward to the next observed frame; no future
    points enter a request. No requests/held terminal frames are invented after
    the clip. Network, scheduling and inference delays are deliberately omitted.
    """
    if not 0 < window_ms <= 2000 or interval_ms <= 0 or not 0 <= phase_ms < interval_ms:
        raise ValueError("Invalid window, interval, or poll phase.")
    if any(b["timestampMS"] <= a["timestampMS"] for a, b in zip(frames, frames[1:])):
        raise ValueError("Frame timestamps must strictly increase.")
    if not frames:
        return {"events": [], "requests": 0, "onsets": [], "raw_labels": []}
    start = frames[0]["timestampMS"]
    due = start + phase_ms
    state = DisplayFilter()
    visible = None
    events, onsets, raw_labels = [], [], []
    requests = 0
    for i, frame in enumerate(frames):
        t = frame["timestampMS"]
        if not frame["hands"]:
            state.reset()
            visible = None
            events.append({"t_ms": t-start, "reset": True, "expected": None})
            # RemoteRecognition polls every 200ms when no hands are present.
            if t >= due:
                due = t + 200
            continue
        if t < due:
            continue
        window = [f for f in frames[:i+1] if f["timestampMS"] >= t-window_ms]
        result = classify(window)
        label = result["candidates"][0]["label"] if not result["unknown"] else None
        raw_labels.append(label)
        requests += 1
        next_visible = state.update(label)
        if next_visible is not None and next_visible != visible:
            onsets.append({"label": next_visible, "t_ms": t-start})
        visible = next_visible
        events.append({"t_ms": t-start, "reset": False, "label": label, "expected": visible})
        due = t + interval_ms
    return {"events": events, "requests": requests, "onsets": onsets, "raw_labels": raw_labels}


def summarize(runs):
    """Per clip/phase opportunities; phases of one clip are NOT independent samples."""
    counts = Counter()
    per_label = {}
    delays = []
    for run in runs:
        truth = run["truth"]
        row = per_label.setdefault(truth, Counter())
        labels = [x["label"] for x in run["onsets"]]
        correct = truth != "UNKNOWN" and truth in labels
        wrong = any(label != truth for label in labels)
        raw_correct = truth != "UNKNOWN" and truth in run["raw_labels"]
        for target in (counts, row):
            target["runs"] += 1
            target["known_runs"] += truth != "UNKNOWN"
            target["unsupported_runs"] += truth == "UNKNOWN"
            target["correct_visible_runs"] += correct
            target["wrong_visible_runs"] += wrong
            target["raw_wrong_runs"] += any(label is not None and label != truth
                                            for label in run["raw_labels"])
            target["raw_correct_runs"] += raw_correct
            target["no_visible_runs"] += not labels
            target["repeated_same_label_runs"] += len(labels) != len(set(labels))
            target["requests"] += run["requests"]
        if correct:
            delays.append(next(x["t_ms"] for x in run["onsets"] if x["label"] == truth))
    return {**dict(counts), "per_label": {k: dict(v) for k, v in sorted(per_label.items())},
            "correct_first_display_from_clip_start_median_ms":
                statistics.median(delays) if delays else None}


def evaluate_stream(corpus, matcher, *, interval_ms=1000, phases=(0, 333, 667), window_ms=1200):
    if not phases or len(set(phases)) != len(phases):
        raise ValueError("Need distinct poll phases.")
    runs = []
    test = [s for s in corpus["samples"] if s["split"] == "test"]
    for sample in test:
        for phase in phases:
            result = replay_clip(sample["frames"], matcher.classify, window_ms=window_ms,
                                 interval_ms=interval_ms, phase_ms=phase)
            runs.append({"id": sample["id"], "truth": sample["label"],
                         "phase_ms": phase, **result})
    return {
        "protocol": "rolling-isolated-clips-v1",
        "scope": "Previously inspected research clips; diagnostic, NOT a fresh accuracy estimate.",
        "limitations": [
            "No network/inference delay; camera polling snapped to available recorded frames.",
            "Isolated clips with cold buffers, not continuous signing or natural transitions.",
            "No onset annotations; first display is timed from clip start, NOT sign onset.",
            "Multiple phases of a clip are correlated; do not treat runs as independent trials.",
            "Repeated display onsets are not caption tokens; no transcript emitter is simulated.",
        ],
        "model": matcher.model_name,
        "parameters": {"max_distance": matcher.max_distance, "min_margin": matcher.min_margin,
                       "window_ms": window_ms, "interval_ms": interval_ms, "phases_ms": list(phases)},
        "distinct_test_clips": len(test),
        "summary": summarize(runs), "runs": runs,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("corpus", type=Path)
    parser.add_argument("calibration_report", type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--interval-ms", type=int, default=1000,
                        help="Diagnostic polling interval, does not modify app configuration.")
    args = parser.parse_args()
    # Reuse strict SHA/model binding and local-only research safeguards.
    service = reference_service(args.corpus, args.calibration_report, "127.0.0.1")
    if args.interval_ms < 3:
        parser.error("--interval-ms must be >= 3")
    phases = (0, args.interval_ms // 3, 2 * args.interval_ms // 3)
    report = evaluate_stream(load_corpus(args.corpus), service.matcher,
                             interval_ms=args.interval_ms, phases=phases)
    report["corpus_sha256"] = json.loads(args.calibration_report.read_text())["corpus_sha256"]
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    print(json.dumps({k: v for k, v in report.items() if k != "runs"}, indent=2))


if __name__ == "__main__":
    main()
