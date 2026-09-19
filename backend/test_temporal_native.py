"""Compile the actual Swift temporal engine and compare locally to Python V2.

Defaults to synthetic geometry, NOT ASL. Optional research corpus stays local:
no model calls, uploads, app bundling, or deployment. Uses temporary fixtures
deleted after the test; prints only aggregate parity and timing.
"""
from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path
import random
import subprocess
import tempfile

from .matcher import TrackedReferenceMatcher, load_corpus
from .server import reference_service
from .service import ServiceError
from .test_matcher import geometry, sample

ROOT = Path(__file__).resolve().parent.parent


def with_scores(frames):
    result = copy.deepcopy(frames)
    for frame in result:
        for hand in frame["hands"]:
            hand.setdefault("handednessScore", .5)
    return result


def synthetic():
    references = [sample("a", "YES", with_scores(geometry())),
                  sample("b", "NO", with_scores(geometry(3)))]
    matcher = TrackedReferenceMatcher(references, max_distance=.1, min_margin=.15)
    queries = [[], with_scores(geometry(count=4)), with_scores(geometry()),
               with_scores(geometry(20)), with_scores(geometry(reverse=True)),
               with_scores(geometry(count=23, scale=.7, offset=.1))]
    for mode in ("duplicate", "flip", "order", "missing", "gap", "ambiguous", "mirror",
                 "aspect", "degenerate", "clamped_score", "bad_timestamp", "bad_joints",
                 "bad_side", "bad_coordinate", "bad_aspect", "too_long", "too_many",
                 "canonical_out_of_bounds"):
        frames = with_scores(geometry())
        for i, frame in enumerate(frames):
            h = frame["hands"][0]
            if mode == "duplicate":
                frame["hands"].append(copy.deepcopy(h))
            elif mode == "flip" and i == 6:
                h["handedness"] = "Left"
            elif mode == "order":
                other = copy.deepcopy(h)
                other["handedness"] = "Left"
                for p in other["joints"]:
                    p["x"] += .4
                frame["hands"].append(other)
                if i % 2:
                    frame["hands"].reverse()
            elif mode == "missing" and i % 3 == 0:
                frame["hands"] = []
            elif mode == "gap" and i > 7:
                frame["timestampMS"] += 400
            elif mode == "ambiguous":
                h["handedness"] = "Hand"
            elif mode == "mirror":
                frame["mirrored"] = False
                h["handedness"] = "Left"
                for p in h["joints"]:
                    p["x"] = 1-p["x"]
            elif mode == "aspect":
                frame["imageAspectRatio"] = 2
                for p in h["joints"]:
                    p["x"] /= 2
                    p["z"] /= 2
            elif mode == "degenerate":
                h["joints"] = [{"x": .5, "y": .5, "z": 0.}] * 21
            elif mode == "clamped_score":
                # Use an out-of-range finite score in JSON (clamped in both).
                h["handednessScore"] = 4.
            elif mode == "bad_timestamp":
                frame["timestampMS"] = 0
            elif mode == "bad_joints":
                h["joints"] = h["joints"][:20]
            elif mode == "bad_side":
                h["handedness"] = "invalid"
            elif mode == "bad_coordinate":
                h["joints"][0]["x"] = 11
            elif mode == "bad_aspect":
                frame["imageAspectRatio"] = .01
            elif mode == "too_long":
                frame["timestampMS"] *= 4
            elif mode == "canonical_out_of_bounds":
                frame["imageAspectRatio"] = 10
                for p in h["joints"]:
                    p["x"] += 2
        if mode == "too_many":
            frames = [copy.deepcopy(frames[0]) for _ in range(91)]
            for i, frame in enumerate(frames):
                frame["timestampMS"] = i
        queries.append(frames)
    rng = random.Random(20260919)
    for _ in range(100):
        frames = with_scores(geometry(rng.randrange(5), count=rng.randint(6, 40)))
        for frame in frames:
            for h in frame["hands"]:
                for p in h["joints"]:
                    p["x"] += rng.uniform(-.005, .005)
                    p["y"] += rng.uniform(-.005, .005)
        queries.append(frames)
    return references, matcher, queries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path)
    parser.add_argument("--calibration-report", type=Path)
    args = parser.parse_args()
    if bool(args.corpus) != bool(args.calibration_report):
        parser.error("Both corpus and calibration report are required.")
    if args.corpus:
        corpus = load_corpus(args.corpus)
        matcher = reference_service(args.corpus, args.calibration_report, "127.0.0.1").matcher
        if matcher.model_name != "reference-dtw-v2":
            parser.error("Native implementation matches V2 only.")
        references = [s for s in corpus["samples"] if s["split"] == "train" and s["label"] != "UNKNOWN"]
        queries = [s["frames"] for s in corpus["samples"]]
        # Also compare causal rolling windows at 250ms, not just whole clips.
        for sample_row in corpus["samples"]:
            if sample_row["split"] != "test":
                continue
            due = 0
            for i, frame in enumerate(sample_row["frames"]):
                t = frame["timestampMS"]
                if t >= due:
                    queries.append([f for f in sample_row["frames"][:i+1] if f["timestampMS"] >= t-1200])
                    due = t+250
    else:
        references, matcher, queries = synthetic()
    fixture = {"references": references, "maxDistance": matcher.max_distance,
               "minMargin": matcher.min_margin, "queries": []}
    for frames in queries:
        try:
            expected = matcher.classify(frames)
            invalid = False
        except ServiceError:
            expected = None
            invalid = True
        fixture["queries"].append({"frames": frames, "expected": expected, "invalid": invalid})
    with tempfile.TemporaryDirectory(prefix="signloop-native-parity-") as directory:
        path = Path(directory)
        source = path / "fixture.json"
        source.write_text(json.dumps(fixture, allow_nan=False))
        binary = path / "replay"
        subprocess.run(["swiftc", "-O", "-parse-as-library",
                        str(ROOT / "ios/Signloop/Recognition.swift"),
                        str(ROOT / "ios/Signloop/TemporalReferenceMatcher.swift"),
                        str(ROOT / "ios/Tests/TemporalMatcherReplay.swift"),
                        "-o", str(binary)], check=True)
        subprocess.run([str(binary), str(source)], check=True)


if __name__ == "__main__":
    main()
