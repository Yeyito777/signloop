"""Create local native-runtime fixtures. Never captures/uploads video.

Default fixtures are synthetic and may be provisioned to a developer phone.
Explicit restricted-research mode is local-simulator-only, never for a phone.
"""
import argparse
import json
from pathlib import Path

from .research_pretrained import PretrainedResearchMatcher, ranked_logits
from .service import ServiceError
from .test_temporal_native import synthetic
from .matcher import load_corpus


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--vocabulary", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--research-corpus", type=Path)
    parser.add_argument("--local-simulator-only", action="store_true")
    args = parser.parse_args()
    matcher = PretrainedResearchMatcher(args.model, args.vocabulary)
    matcher.min_score, matcher.min_margin = .4, .05
    if bool(args.research_corpus) != args.local_simulator_only:
        parser.error("Research corpus requires --local-simulator-only (never provision to a phone).")
    if args.research_corpus:
        if ".runtime" not in args.out.parts:
            parser.error("Restricted fixtures must stay in an ignored .runtime directory.")
        corpus = load_corpus(args.research_corpus)
        queries = [s["frames"] for s in corpus["samples"] if s["split"] != "train"]
        source = "LOCAL_RESEARCH_ONLY_ASL_CITIZEN"
    else:
        _, _, queries = synthetic()
        source = "SYNTHETIC_GEOMETRY_NOT_ASL"
    fixture = {"source": source, "queries": []}
    for frames in queries:
        try:
            tensor = matcher.tensor(frames)
        except ServiceError:
            continue  # Invalid-frame behavior has separate contract tests.
        logits = matcher.run(inputs=tensor)["outputs"].tolist() if tensor is not None else None
        decision = matcher.decide(ranked_logits(logits, matcher.vocabulary) if logits is not None else [])
        fixture["queries"].append({"frames": frames, "logits": logits, "unknown": decision["unknown"],
                                   "acceptedLabel": None if decision["unknown"] else
                                       decision["candidates"][0]["label"]})
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(fixture, allow_nan=False))
    print(f"{source}: saved {len(fixture['queries'])} local queries. Parity, not ASL accuracy evidence.")


if __name__ == "__main__":
    main()
