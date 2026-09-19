"""Prepare the ORIGINAL calibration cohort at current tracking cadence.

Local restricted research only. No test/additional clips, network or model
threshold selection here; the native simulator owns the fixed policy grid.
"""
import argparse
import hashlib
import json
from pathlib import Path

from .research_data import LICENSE
from .research_holdout import observe
from .research_static import MODEL_SHA

CORPUS_SHA = "fc86b68b116b31d593af34b2c5b436b8a190f42d4c9c56c0a6d0e4865cec794b"


def calibration_samples(path):
    if hashlib.sha256(path.read_bytes()).hexdigest() != CORPUS_SHA:
        raise ValueError("Use the original, pinned V2 corpus, not an additional/test cohort.")
    samples = [s for s in json.loads(path.read_text())["samples"] if s["split"] == "calibration"]
    if len(samples) != 32 or len({s["signer"] for s in samples}) != 4:
        raise ValueError("Unexpected original calibration cohort.")
    return samples


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--clips", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, default=Path(".runtime/confirmation-calibration"))
    parser.add_argument("--accept-research-license", action="store_true")
    args = parser.parse_args()
    if not args.accept_research_license or ".runtime" not in args.out_dir.parts:
        parser.error(f"Read {LICENSE}; explicitly accept and keep output under ignored .runtime.")
    if hashlib.sha256(args.model.read_bytes()).hexdigest() != MODEL_SHA:
        parser.error("Unexpected gesture model.")
    samples = calibration_samples(args.corpus)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    result = []
    for i, sample in enumerate(samples):
        cached = args.out_dir/(sample["id"]+".json")
        if cached.exists():
            observation = json.loads(cached.read_text())
        else:
            observation = observe(args.clips/(sample["id"]+".mp4"), args.model)
            cached.write_text(json.dumps(observation, allow_nan=False))
        result.append({"split": "calibration", "label": sample["label"], **observation})
        print(f"{i+1}/{len(samples)} original calibration clips prepared", flush=True)
    (args.out_dir/"live-replay-fixture.json").write_text(json.dumps({
        "source": "LOCAL_RESEARCH_ONLY_ASL_CITIZEN", "corpus_sha256": CORPUS_SHA,
        "clips": result}, allow_nan=False))


if __name__ == "__main__":
    main()
