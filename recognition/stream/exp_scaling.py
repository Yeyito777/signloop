"""Experiment A: does accuracy collapse as the candidate vocabulary grows? Raw whole-clip inference,
every provider, WLASL val split (never used for training or checkpoint selection) and test split
(used by OpenHands for checkpoint selection: optimistic, reported separately).

    python -m recognition.stream.exp_scaling --out .runtime/stream/scaling.json
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

from .cache import get_logits
from .metrics import restrict, softmax, topk_acc, wilson
from .openhands_provider import ARCHS, OpenHandsProvider, ROOT
from .poseio import WLASLPoses, nested_random_vocab, official_subset

SIZES = (16, 100, 500, 1000, 2000)


def run(out: str, splits=("val", "test"), seeds=5):
    P = WLASLPoses(ROOT / "WLASL_pose.zip", ROOT / "wlasl_metadata/splits/asl2000.json")
    result = {"note": "raw whole-clip inference; softmax over the active vocabulary only", "splits": {}}
    providers = {a: OpenHandsProvider(a, P.glosses) for a in ARCHS}
    for split in splits:
        items = P.split(split)
        y = np.array([c for _, c, _ in items])
        logits = {}
        secs = {}
        for a, prov in providers.items():
            logits[a], secs[a] = get_logits(prov, f"whole_{split}", lambda: [P.window(v) for v, _, _ in items])
        ens = {"mean_prob": lambda ps: np.mean(ps, 0), "geo_mean": lambda ps: np.exp(np.mean(np.log(np.clip(ps, 1e-9, 1)), 0))}
        res = {"n_clips": len(items), "seconds": secs, "random_nested": {}, "official": {}}
        for size in SIZES:
            rows = {}
            for seed in range(seeds if size < 2000 else 1):
                vocab = nested_random_vocab(len(P.glosses), [size], seed)[size]
                probs = {}
                for a in providers:
                    p, yl, keep = restrict(logits[a], y, vocab)
                    probs[a] = softmax(p)
                    rows.setdefault(a, []).append(topk_acc(probs[a], yl))
                for name, fn in ens.items():
                    rows.setdefault(f"ens:{name}", []).append(topk_acc(fn(np.stack(list(probs.values()))), yl))
            res["random_nested"][size] = {k: {m: float(np.mean([r[m] for r in v])) for m in v[0]} |
                                          {"top1_std_over_vocab_draws": float(np.std([r["top1"] for r in v]))} for k, v in rows.items()}
        for size in (100, 300, 1000):
            names = official_subset(ROOT / "wlasl_metadata/splits", size)
            vocab = np.array(sorted(P.gloss_id[g] for g in names))
            rows = {}
            probs = {}
            for a in providers:
                p, yl, keep = restrict(logits[a], y, vocab)
                probs[a] = softmax(p)
                rows[a] = topk_acc(probs[a], yl)
            rows["ens:mean_prob"] = topk_acc(np.mean(list(probs.values()), 0), yl)
            res["official"][size] = rows
        result["splits"][split] = res
    Path(out).write_text(json.dumps(result, indent=1))
    return result


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    r = run(a.out)
    for split, res in r["splits"].items():
        print("==", split, res["n_clips"], "clips")
        for size, rows in res["random_nested"].items():
            print(size, {k: round(v["top1"], 3) for k, v in rows.items()}, {k: round(v["top5"], 3) for k, v in rows.items() if k.startswith("ens")})
