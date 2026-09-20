"""Experiment E: how early is the evidence usable? Accuracy when only the first t seconds of a sign clip
have been seen (an expanding window anchored at clip start), per provider and fused, vocab 100/500.
Isolated recognizers were trained on whole clips, so partial evidence is out-of-distribution; this measures how much.
    python -m recognition.stream.exp_prefix --out .runtime/stream/prefix.json
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

from . import fusion
from .cache import get_logits
from .exp_stream import select_clips
from .metrics import softmax, topk_acc
from .openhands_provider import ARCHS, OpenHandsProvider, ROOT
from .poseio import FPS, WLASLPoses, nested_random_vocab

TIMES = (0.5, 0.75, 1.0, 1.5, 2.0, 3.0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    P = WLASLPoses(ROOT / "WLASL_pose.zip", ROOT / "wlasl_metadata/splits/asl2000.json")
    providers = {k: OpenHandsProvider(k, P.glosses) for k in ARCHS}
    clips, val_idx = select_clips(P)
    y = np.array([c for _, c, _ in clips])
    dur = np.array([len(P.clip(v)[0]) / FPS for v, _, _ in clips])
    L = {t: {} for t in TIMES}
    for t in TIMES:
        for k, prov in providers.items():
            L[t][k], _ = get_logits(prov, f"prefix_{t}_val{len(clips)}", lambda: [P.window(v, 0.0, t) for v, _, _ in clips])
    res = {"times_s": TIMES, "clip_duration_median_s": float(np.median(dur)), "vocab": {}}
    for size in (100, 500):
        vocab = nested_random_vocab(len(P.glosses), [size], 0)[size]
        pos = -np.ones(len(P.glosses), int); pos[vocab] = np.arange(size)
        keep = pos[y] >= 0; yl = pos[y[keep]]
        rows = {}
        for t in TIMES:
            PW = {k: softmax(L[t][k][keep][:, vocab]) for k in providers}
            for k in PW:
                rows.setdefault(k, {})[t] = topk_acc(PW[k], yl)
            rows.setdefault("ens:geo_mean", {})[t] = topk_acc(fusion.geo_mean(list(PW.values())), yl)
        res["vocab"][size] = rows
        print("vocab", size, {t: (round(rows["ens:geo_mean"][t]["top1"], 3), round(rows["ens:geo_mean"][t]["top5"], 3)) for t in TIMES}, flush=True)
    Path(a.out).write_text(json.dumps(res, indent=1))


if __name__ == "__main__":
    main()
