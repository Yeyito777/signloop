"""Calibration-only NO articulation guard experiment; no downloads or uploads."""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
from pathlib import Path
import random
import statistics

from .matcher import load_corpus
from .research_pretrained import PretrainedResearchMatcher
from .stream_calibrate import prepare, decide_runs
from .stream_replay import summarize


def pinch_motion(frames):
    """Largest sustained thumb/index/middle aperture change in palm units.

    XY uses image aspect ratio. Translation/scale cancel; reflection is
    immaterial. Three-frame median suppresses isolated jitter. Never bridge
    missing/duplicate side assignments, aspect changes or >150ms tracking gaps.
    This is an articulation cue, NOT an independent NO recognizer.
    """
    best = 0.
    for side in ("Left", "Right"):
        segment = []
        previous = None
        previous_metadata = None
        for frame in frames:
            metadata = (frame.get("imageAspectRatio", 1), frame.get("mirrored", True))
            hands = [h for h in frame["hands"] if h["handedness"] == side]
            timestamp = frame["timestampMS"]
            if (len(hands) != 1 or previous is None or
                    not 0 < timestamp-previous <= 150 or metadata != previous_metadata):
                segment = []
            previous, previous_metadata = timestamp, metadata
            if len(hands) != 1:
                continue
            points = hands[0]["joints"]
            aspect = metadata[0]
            def distance(a, b):
                return math.hypot((points[a]["x"]-points[b]["x"])*aspect,
                                  points[a]["y"]-points[b]["y"])
            scale = distance(0, 9)
            if scale < .01 or not math.isfinite(scale):
                segment = []
                continue
            aperture = (distance(4, 8)+distance(4, 12))/(2*scale)
            segment.append(aperture)
            if len(segment) >= 6:
                smooth = [statistics.median(segment[i:i+3]) for i in range(len(segment)-2)]
                best = max(best, max(smooth)-min(smooth))
    return best


class MotionMatcher(PretrainedResearchMatcher):
    model_name = "kaggle-islr-250-hands-motion-research-v2"

    def __init__(self, model, vocabulary):
        super().__init__(model, vocabulary)
        # Freeze the previous score policy; only the new articulation threshold
        # is calibrated here. No test-derived confidence retuning.
        self.min_score, self.min_margin = .4, .05
        self.min_motion = math.inf

    def rank(self, frames):
        ranked = super().rank(frames)
        if ranked:
            ranked[0]["pinch_motion"] = pinch_motion(frames)
        return ranked

    def decide(self, ranked):
        result = super().decide(ranked)
        if (not result["unknown"] and ranked[0]["label"] == "NO" and
                ranked[0].get("pinch_motion", 0) < self.min_motion):
            result["unknown"] = True
            result["reason"] = "insufficient_articulation"
        return result


def challenges(samples):
    """Fixed-seed synthetic stationary/noisy poses, never natural negatives."""
    rng = random.Random(20260919)
    for sample in samples:
        for fraction in (0, .5, 1):
            pose = sample["frames"][round((len(sample["frames"])-1)*fraction)]
            for noise in (0., .005, .01, .02):
                window = []
                for i in range(19):
                    frame = copy.deepcopy(pose)
                    frame["timestampMS"] = i*67
                    aspect = frame.get("imageAspectRatio", 1)
                    for hand in frame["hands"]:
                        points = hand["joints"]
                        scale = math.hypot((points[0]["x"]-points[9]["x"])*aspect,
                                           points[0]["y"]-points[9]["y"])
                        for p in points:
                            p["x"] += rng.uniform(-noise, noise)*scale/aspect
                            p["y"] += rng.uniform(-noise, noise)*scale
                    window.append(frame)
                yield noise, window


def choose(prepared, probes, matcher):
    best, chosen = None, None
    for threshold in (0., .025, .05, .075, .1, .15, .2, .3, .4, .6, 1., 2., math.inf):
        matcher.min_motion = threshold
        if any(not matcher.decide(rank)["unknown"] for _, rank in probes):
            continue
        summary = summarize(decide_runs(prepared, matcher))
        if summary["wrong_visible_runs"]:
            continue
        # Retain calibration coverage, then choose the least restrictive gate.
        objective = (summary["correct_visible_runs"], -threshold)
        if best is None or objective > best:
            best, chosen = objective, threshold
    if chosen is None:
        raise ValueError("No safe calibration point; do not enable this guard.")
    matcher.min_motion = chosen
    return chosen


def evaluate(corpus, matcher):
    calibration = [s for s in corpus["samples"] if s["split"] == "calibration"]
    prepared = prepare(calibration, matcher)
    probes = [(noise, matcher.rank(window)) for noise, window in challenges(calibration)]
    matcher.min_motion = 0
    baseline = summarize(decide_runs(prepared, matcher))
    baseline_probes = sum(not matcher.decide(rank)["unknown"] for _, rank in probes)
    threshold = choose(prepared, probes, matcher)
    calibrated = summarize(decide_runs(prepared, matcher))
    probe_summary = {str(noise): {
        "windows": sum(n == noise for n, _ in probes),
        "accepted": sum(n == noise and not matcher.decide(r)["unknown"] for n, r in probes)
    } for noise in (0., .005, .01, .02)}
    # First access to test frames: after policy selection.
    test = [s for s in corpus["samples"] if s["split"] == "test"]
    runs = decide_runs(prepare(test, matcher), matcher)
    return {
        "protocol": "pretrained-articulation-calibration-v1",
        "model": matcher.model_name,
        "parameters": {"min_score": .4, "min_margin": .05,
                       "min_motion": threshold if math.isfinite(threshold) else "reject_all_NO"},
        "scope": "Previously inspected research clips; not fresh or phone validation. "
                 "Synthetic pose jitter is not natural nonsigning evidence.",
        "calibration_baseline": baseline, "calibration": calibrated,
        "synthetic_baseline_accepted": baseline_probes, "synthetic": probe_summary,
        "test": summarize(runs), "runs": runs,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("corpus", type=Path)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--vocabulary", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    report = evaluate(load_corpus(args.corpus), MotionMatcher(args.model, args.vocabulary))
    report["corpus_sha256"] = hashlib.sha256(args.corpus.read_bytes()).hexdigest()
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2, allow_nan=False)+"\n")
    print(json.dumps({k: v for k, v in report.items() if k != "runs"}, indent=2))


if __name__ == "__main__":
    main()
