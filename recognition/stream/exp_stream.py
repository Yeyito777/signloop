"""Experiment B: overlapping-window streaming vs raw whole-clip, with aggregation and multi-provider fusion.

Real inference throughout (cached logits). Isolated WLASL clips stand in for a stream: each clip is
fed as a timeline and windows slide across it. This is NOT continuous signing (see docs).
    python -m recognition.stream.exp_stream --out .runtime/stream/stream.json
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

from . import fusion, temporal
from .cache import get_logits
from .metrics import softmax, topk_acc
from .openhands_provider import ARCHS, OpenHandsProvider, ROOT
from .poseio import FPS, WLASLPoses, nested_random_vocab

N_CLIPS, WIDTH, STRIDE = 800, 1.0, 0.25
SIZES = (16, 100, 500, 2000)


def select_clips(P, n=N_CLIPS, seed=0):
    vals = P.split("val")
    idx = np.random.default_rng(seed).choice(len(vals), n, replace=False)
    return [vals[i] for i in sorted(idx)], sorted(idx)


def window_plan(P, clips, width, stride):
    """[(clip_index, t0, t1)] for every window of every clip."""
    plan = []
    for ci, (vid, _, _) in enumerate(clips):
        kp, _ = P.clip(vid)
        for t0, t1 in temporal.make_windows(len(kp) / FPS, width, stride):
            plan.append((ci, t0, t1))
    return plan


def load_all(P, providers, clips, val_idx, width=WIDTH, stride=STRIDE):
    plan = window_plan(P, clips, width, stride)
    wl, whole = {}, {}
    vals = P.split("val")
    for a, prov in providers.items():
        wl[a], _ = get_logits(prov, f"win_{width}_{stride}_val{len(clips)}",
                              lambda: [P.window(clips[ci][0], t0, t1) for ci, t0, t1 in plan])
        full, _ = get_logits(prov, "whole_val", lambda: [P.window(v) for v, _, _ in vals])
        whole[a] = full[val_idx]
    ci = np.array([p[0] for p in plan])
    return plan, ci, wl, whole


def per_clip(idx_lists, fn, probs):
    return np.stack([fn(probs[ix]) for ix in idx_lists])


def evaluate(P, clips, plan, ci, wl, whole, sizes=SIZES, draws=5, agg="mean"):
    y = np.array([c for _, c, _ in clips])
    groups = [np.flatnonzero(ci == i) for i in range(len(clips))]
    fold_a = np.arange(len(clips)) % 2 == 0          # tune / weight estimation
    fold_b = ~fold_a                                 # report
    out = {}
    for size in sizes:
        rows = {}
        for seed in range(draws if size < 2000 else 1):
            vocab = nested_random_vocab(len(P.glosses), [size], seed)[size]
            pos = -np.ones(len(P.glosses), int)
            pos[vocab] = np.arange(size)
            keep = pos[y] >= 0
            yl = pos[y[keep]]
            rep = keep & fold_b
            rep_local = pos[y[rep]]
            sel = lambda arr, m: arr[m]
            PW = {a: softmax(wl[a][:, vocab]) for a in wl}                     # per-window probs
            PC = {a: softmax(whole[a][:, vocab]) for a in whole}               # whole-clip probs
            # weights from fold A (whole-clip top-1)
            ka = keep & fold_a
            acc = {a: float((PC[a][ka].argmax(1) == pos[y[ka]]).mean()) for a in PC}
            w = np.array([acc[a] for a in PW])
            def record(name, S):
                rows.setdefault(name, []).append(topk_acc(S[rep], rep_local))
            for a in PW:
                record(f"raw whole-clip | {a}", PC[a])
                record(f"temporal({agg}) | {a}", per_clip(groups, temporal.AGG[agg], PW[a]))
                # a single window: the last one (what a naive live system would see at sign end)
                record(f"single last window | {a}", np.stack([PW[a][ix[-1]] for ix in groups]))
            for name in ("mean_prob", "geo_mean"):
                fn = getattr(fusion, name)
                record(f"raw whole-clip | ens:{name}", fn(list(PC.values())))
                fused_w = fn(list(PW.values()))
                for ag in ("mean", "geo", "max", "center", "recency"):
                    record(f"temporal({ag}) | ens:{name}", per_clip(groups, temporal.AGG[ag], fused_w))
            wts = w / w.sum()
            fused_w = fusion.mean_prob(list(PW.values()), wts)
            record("temporal(mean) | ens:weighted-by-foldA-acc", per_clip(groups, temporal.agg_mean, fused_w))
            vote_w = fusion.majority_vote(list(PW.values()))
            record("temporal(mean) | ens:majority-vote", per_clip(groups, temporal.agg_mean, vote_w))
            Wrel = fusion.reliability_weights([PC[a][ka] for a in PC], pos[y[ka]], size)
            rel = fusion.class_reliability(list(PW.values()), Wrel)
            record("temporal(mean) | ens:class-reliability", per_clip(groups, temporal.agg_mean, rel))
        out[size] = {k: {m: float(np.mean([r[m] for r in v])) for m in v[0]} for k, v in rows.items()}
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--width", type=float, default=WIDTH)
    ap.add_argument("--stride", type=float, default=STRIDE)
    a = ap.parse_args()
    P = WLASLPoses(ROOT / "WLASL_pose.zip", ROOT / "wlasl_metadata/splits/asl2000.json")
    providers = {k: OpenHandsProvider(k, P.glosses) for k in ARCHS}
    clips, val_idx = select_clips(P)
    plan, ci, wl, whole = load_all(P, providers, clips, val_idx, a.width, a.stride)
    print(f"{len(clips)} clips, {len(plan)} windows (W={a.width}s stride={a.stride}s)")
    res = evaluate(P, clips, plan, ci, wl, whole)
    res["_meta"] = {"n_clips": len(clips), "n_windows": len(plan), "width": a.width, "stride": a.stride,
                    "report_fold": "odd-indexed clips (fold B); fold A (even) used only for weights"}
    Path(a.out).write_text(json.dumps(res, indent=1))
    for size in SIZES:
        print("== vocab", size)
        for k, v in res[size].items():
            print(f"  {k:52s} top1 {v['top1']:.3f} top3 {v['top3']:.3f} top5 {v['top5']:.3f} top10 {v['top10']:.3f}")


if __name__ == "__main__":
    main()
