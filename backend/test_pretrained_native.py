"""Pure Swift tensor/logit contract regression: no downloaded model required.

Uses artificial logits and synthetic geometry, NOT model/ASL accuracy evidence.
"""
import json
import math
from pathlib import Path
import random
import struct
import subprocess
import tempfile

from .research_pretrained import PretrainedResearchMatcher, ranked_logits
from .service import ServiceError, validate_frames
from .test_pretrained import vocabulary
from .test_temporal_native import synthetic


def main():
    root = Path(__file__).resolve().parent.parent
    vocab = vocabulary()
    matcher = object.__new__(PretrainedResearchMatcher)
    matcher.min_score, matcher.min_margin = .4, .05
    rng = random.Random(20260919)
    fixture = {"source": "SYNTHETIC_POLICY_TEST_NOT_MODEL_OUTPUT", "queries": []}
    _, _, queries = synthetic()
    for index, frames in enumerate(queries):
        try:
            validate_frames(frames)
        except ServiceError:
            continue
        eligible = (len(frames) >= 6 and bool(frames[-1]["hands"])
                    and sum(bool(f["hands"]) for f in frames)*2 >= len(frames)
                    and any(h["handedness"] in ("Left", "Right") for f in frames for h in f["hands"]))
        logits = None
        if eligible:
            logits = [rng.uniform(-2, 2) for _ in range(250)]
            if index % 3 == 0:
                logits[index % 250] = 15
            if index % 10 < 3:
                # Deliberately test scores immediately around the exact cutoff.
                probability = (.399999, .4, .400001)[index % 10]
                logits = [0.]*250
                logits[0] = math.log(probability*249/(1-probability))
            logits = [struct.unpack("f", struct.pack("f", x))[0] for x in logits]
        result = matcher.decide(ranked_logits(logits, vocab) if logits is not None else [])
        fixture["queries"].append({"frames": frames, "logits": logits, "unknown": result["unknown"],
                                   "acceptedLabel": None if result["unknown"] else result["candidates"][0]["label"]})
    with tempfile.TemporaryDirectory(prefix="signloop-policy-test-") as directory:
        folder = Path(directory)
        (folder/"fixture.json").write_text(json.dumps(fixture, allow_nan=False))
        (folder/"vocabulary.json").write_text(json.dumps(vocab))
        binary = folder/"policy-replay"
        subprocess.run(["swiftc", "-parse-as-library",
                        str(root/"ios/Signloop/Recognition.swift"),
                        str(root/"ios/Signloop/PretrainedSignPolicy.swift"),
                        str(root/"ios/Tests/PretrainedPolicyReplay.swift"), "-o", str(binary)], check=True)
        subprocess.run([str(binary), str(folder/"fixture.json"), str(folder/"vocabulary.json")], check=True)


if __name__ == "__main__":
    main()
