"""Local research of a published 250-word ISLR model; NOT a runtime service.

No downloads/uploads, no bundled weights, no dataset redistribution. Optional
dependencies: ai-edge-litert==2.2.0 and numpy. Original weight licensing still
needs clarification before distribution (mirror says MIT; original says Unknown).
"""
from __future__ import annotations

import argparse
import copy
from collections import Counter
import hashlib
import json
import math
from pathlib import Path

from .matcher import load_corpus
from .service import validate_frames
from .stream_calibrate import prepare, decide_runs
from .stream_replay import summarize

MODEL_SHA = "f55a2bb1ebe6d1e912a98e31c6ef3f995c9ae261f408fe115f2008099d3f0bb7"
VOCAB_SHA = "1fe747c2f44c68dbb396947e35193c96d363f3dede0be8defa5e08546400bf5d"
SUPPORTED = {"hello": "HELLO", "yes": "YES", "no": "NO", "please": "PLEASE", "thankyou": "THANK_YOU"}


def ranked_logits(logits, vocabulary):
    if len(logits) != 250 or any(not math.isfinite(x) for x in logits):
        raise ValueError("Expected 250 finite model logits.")
    if len(vocabulary) != 250 or set(vocabulary.values()) != set(range(250)):
        raise ValueError("Expected a complete 250-label vocabulary.")
    inverse = {v: k for k, v in vocabulary.items()}
    maximum = max(logits)
    exps = [math.exp(x-maximum) for x in logits]
    denominator = sum(exps)
    # Rank ALL classes, not just supported ones. An unrelated word must not be
    # forced into the demo vocabulary by renormalizing five selected logits.
    indices = sorted(range(250), key=lambda i: -logits[i])[:2]
    return [{"label": SUPPORTED.get(inverse[i], "UNSUPPORTED:"+inverse[i]),
             "score": exps[i]/denominator} for i in indices]


class PretrainedResearchMatcher:
    labels = sorted(SUPPORTED.values())
    model_name = "kaggle-islr-250-hands-research-v1"

    def __init__(self, model: Path, vocabulary: Path):
        for path, expected in ((model, MODEL_SHA), (vocabulary, VOCAB_SHA)):
            if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
                raise ValueError("Unrecognized model/vocabulary bytes.")
        import numpy as np
        from ai_edge_litert.interpreter import Interpreter
        self.np = np
        self.vocabulary = json.loads(vocabulary.read_text())
        self.interpreter = Interpreter(model_path=str(model), num_threads=2)
        if self.interpreter.get_signature_list() != {
            "serving_default": {"inputs": ["inputs"], "outputs": ["outputs"]}
        }:
            raise ValueError("Unexpected inference signature.")
        self.run = self.interpreter.get_signature_runner()
        self.min_score, self.min_margin = 1., 1.

    def tensor(self, frames):
        validate_frames(frames)
        np = self.np
        if len(frames) < 6 or not frames[-1]["hands"]:
            return None
        if sum(bool(f["hands"]) for f in frames) < .5*len(frames):
            return None
        # Competition layout: face[0:468], left hand[468:489],
        # pose[489:522], right hand[522:543]. Missing landmarks are NaN,
        # never invented face/body coordinates. The model owns normalization.
        tensor = np.full((len(frames), 543, 3), np.nan, dtype=np.float32)
        for i, frame in enumerate(frames):
            mirrored = frame.get("mirrored", True)
            choices = {}
            for hand in frame["hands"]:
                side = hand["handedness"]
                if not mirrored:
                    side = {"Left": "Right", "Right": "Left"}.get(side, side)
                if side not in ("Left", "Right"):
                    continue
                score = hand.get("handednessScore", .5)
                if not isinstance(score, (int, float)) or not math.isfinite(score):
                    score = .5
                # Deterministic duplicate-label handling, independent of result
                # array order. No second physical hand is invented.
                priority = (max(0, min(1, score)),
                            tuple(-p[a] for p in hand["joints"] for a in ("x", "y", "z")))
                if side not in choices or priority > choices[side][0]:
                    choices[side] = (priority, hand)
            for side, (_, hand) in choices.items():
                start = 468 if side == "Left" else 522
                for j, point in enumerate(hand["joints"]):
                    tensor[i, start+j] = (
                        point["x"] if mirrored else 1-point["x"], point["y"], point["z"])
        if not np.isfinite(tensor[:, 468:489]).any() and not np.isfinite(tensor[:, 522:543]).any():
            return None
        return tensor

    def rank(self, frames):
        tensor = self.tensor(frames)
        if tensor is None:
            return []
        logits = self.run(inputs=tensor)["outputs"].tolist()
        return ranked_logits(logits, self.vocabulary)

    def decide(self, ranked):
        accepted = False
        if ranked:
            first, second = ranked
            accepted = (first["label"] in self.labels and first["score"] > self.min_score
                        and first["score"]-second["score"] >= self.min_margin)
        return {"candidates": ranked, "unknown": not accepted,
                "model": self.model_name, "experimental": True}

    def classify(self, frames):
        return self.decide(self.rank(frames))


def calibrate(prepared, matcher):
    best, chosen = None, None
    for score in (i*.05 for i in range(21)):
        for margin in (0, .025, .05, .1, .15, .2, .3, .4):
            matcher.min_score, matcher.min_margin = score, margin
            summary = summarize(decide_runs(prepared, matcher))
            if summary["wrong_visible_runs"]:
                continue
            objective = (summary["correct_visible_runs"], score, margin)
            if best is None or objective > best:
                best, chosen = objective, (score, margin)
    # score > 1 is impossible, so the strict score>threshold gate includes
    # a guaranteed reject-all operating point at threshold 1.
    assert chosen is not None
    matcher.min_score, matcher.min_margin = chosen
    return {"min_score": chosen[0], "min_margin": chosen[1]}


def frozen_probe(samples, matcher):
    """Stationary synthetic challenges, NOT natural nonsigning accuracy."""
    counts, accepted_labels = Counter(), Counter()
    for sample in samples:
        if not sample["frames"]:
            continue
        for fraction in (0, .5, 1):
            frame = sample["frames"][round((len(sample["frames"])-1)*fraction)]
            frozen = [{**copy.deepcopy(frame), "timestampMS": i*67} for i in range(19)]
            result = matcher.classify(frozen)
            counts["frozen_windows"] += 1
            if not result["unknown"]:
                counts["accepted_frozen_windows"] += 1
                accepted_labels[result["candidates"][0]["label"]] += 1
    return {"scope": "Synthetic stationary calibration poses, not natural nonsigning accuracy.",
            **dict(counts), "accepted_labels": dict(accepted_labels)}


def evaluate(corpus, matcher):
    splits = {name: [s for s in corpus["samples"] if s["split"] == name]
              for name in ("calibration", "test")}
    for name, samples in splits.items():
        if not set(matcher.labels) | {"UNKNOWN"} <= {s["label"] for s in samples}:
            raise ValueError(f"{name} requires all supported labels and UNKNOWN.")
    calibration = prepare(splits["calibration"], matcher)
    policy = calibrate(calibration, matcher)
    calibration_runs = decide_runs(calibration, matcher)
    # No test frames are inferred until the operating point is frozen.
    test_runs = decide_runs(prepare(splits["test"], matcher), matcher)
    return {
        "protocol": "pretrained-rolling-research-v1", "model": matcher.model_name,
        "model_sha256": MODEL_SHA, "vocabulary_sha256": VOCAB_SHA,
        "parameters": policy,
        "stream": {"window_ms": 1200, "interval_ms": 250, "phases_ms": [0, 83, 166],
                   "confirmation_results": 2, "simulated_response_delay_ms": 0},
        "scope": "Previously inspected ASL Citizen research clips; not fresh/phone validation. "
                 "Pretrained-model training overlap has not been independently excluded.",
        "input_ablation": "Hands only, missing face/pose=NaN; not the full original model input.",
        "score_kind": "Softmax of model logits across ALL 250 classes; not calibrated probability.",
        "distinct_clips": {k: len(v) for k, v in splits.items()},
        "distinct_signers": {k: len({s['signer'] for s in v}) for k, v in splits.items()},
        "calibration": summarize(calibration_runs), "test": summarize(test_runs),
        "synthetic_stationary_probe": frozen_probe(splits["calibration"], matcher),
        "runs": test_runs,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("corpus", type=Path)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--vocabulary", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    corpus = load_corpus(args.corpus)
    matcher = PretrainedResearchMatcher(args.model, args.vocabulary)
    report = evaluate(corpus, matcher)
    report["corpus_sha256"] = hashlib.sha256(args.corpus.read_bytes()).hexdigest()
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    print(json.dumps({k: v for k, v in report.items() if k != "runs"}, indent=2))


if __name__ == "__main__":
    main()
