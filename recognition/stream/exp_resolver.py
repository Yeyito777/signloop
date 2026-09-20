"""Experiment D: the deterministic temporal resolver's tentative / stable / committed / unknown behavior.

Thresholds are tuned on fold A (even clips) to reach a target commit precision, then reported on fold B.
    python -m recognition.stream.exp_resolver --vocab 100 500 --width 1.5 --out .runtime/stream/resolver.json
"""
from __future__ import annotations

import argparse
from dataclasses import asdict
import itertools
import json
from pathlib import Path

import numpy as np

from . import fusion
from .exp_stream import load_all, select_clips
from .metrics import softmax
from .openhands_provider import ARCHS, OpenHandsProvider, ROOT
from .poseio import WLASLPoses, nested_random_vocab
from .temporal import ResolverConfig, run_stream


def clip_states(P_fused_by_clip, plan_by_clip, cfg):
    return [run_stream(pf, cfg) for pf in P_fused_by_clip]


def evaluate(states, plan_by_clip, y_local, clip_dur, mask):
    n = int(mask.sum())
    committed = correct = unknown = 0
    times, early, flips, tent_ok, tent_n = [], [], 0, 0, 0
    for i in np.flatnonzero(mask):
        st = states[i]
        first = next((k for k, s in enumerate(st) if s["state"] == "committed"), None)
        shown = [s["top"][0][0] for s in st if s["state"] in ("tentative", "stable", "committed")]
        flips += sum(1 for a, b in zip(shown, shown[1:]) if a != b)
        for s in st:
            if s["state"] in ("tentative", "stable", "committed"):
                tent_n += 1
                tent_ok += int(s["top"][0][0] == y_local[i])
        if first is None:
            unknown += 1
            continue
        committed += 1
        correct += int(st[first]["top"][0][0] == y_local[i])
        t1 = plan_by_clip[i][first][1]
        times.append(t1)
        early.append(max(0.0, clip_dur[i] - t1))
    return {"n": n, "coverage": committed / n, "commit_precision": correct / committed if committed else None,
            "correct_committed_of_all": correct / n, "no_commit_rate": unknown / n,
            "tentative_display_accuracy": tent_ok / tent_n if tent_n else None, "display_flips_per_clip": flips / n,
            "median_commit_time_s": float(np.median(times)) if times else None,
            "median_seconds_before_clip_end": float(np.median(early)) if early else None}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vocab", type=int, nargs="+", default=[100, 500])
    ap.add_argument("--width", type=float, default=1.5)
    ap.add_argument("--stride", type=float, default=0.25)
    ap.add_argument("--target", type=float, default=0.8)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    P = WLASLPoses(ROOT / "WLASL_pose.zip", ROOT / "wlasl_metadata/splits/asl2000.json")
    providers = {k: OpenHandsProvider(k, P.glosses) for k in ARCHS}
    clips, val_idx = select_clips(P)
    plan, ci, wl, whole = load_all(P, providers, clips, val_idx, a.width, a.stride)
    y = np.array([c for _, c, _ in clips])
    groups = [np.flatnonzero(ci == i) for i in range(len(clips))]
    plan_by_clip = [[(plan[j][1], plan[j][2]) for j in g] for g in groups]
    clip_dur = np.array([pb[-1][1] for pb in plan_by_clip])
    fold_a = np.arange(len(clips)) % 2 == 0
    grid = [ResolverConfig(tau_s=ts, margin=m, n_stable=ns, n_commit=nc, tau_t=min(0.2, ts), tau_u=0.05)
            for ts, m, ns, nc in itertools.product((0.2, 0.3, 0.45, 0.6), (0.03, 0.1, 0.2), (2, 3), (3, 4))]
    res = {"width": a.width, "stride": a.stride, "target_precision": a.target, "vocab": {}}
    for size in a.vocab:
        vocab = nested_random_vocab(len(P.glosses), [size], 0)[size]
        pos = -np.ones(len(P.glosses), int)
        pos[vocab] = np.arange(size)
        keep = pos[y] >= 0
        yl = np.where(keep, pos[y], -1)
        PW = [softmax(wl[k][:, vocab]) for k in wl]
        fused = fusion.geo_mean(PW)
        seqs = [fused[g] for g in groups]
        best, best_key = None, None
        table = []
        for cfg in grid:
            st = clip_states(seqs, plan_by_clip, cfg)
            m = evaluate(st, plan_by_clip, yl, clip_dur, keep & fold_a)
            table.append((cfg, m))
            prec = m["commit_precision"] if m["commit_precision"] is not None else 0
            key = (prec >= a.target, m["coverage"] if prec >= a.target else prec)
            if best_key is None or key > best_key:
                best, best_key = cfg, key
        st = clip_states(seqs, plan_by_clip, best)
        res["vocab"][size] = {"chosen_on_fold_A": asdict(best), "fold_A": evaluate(st, plan_by_clip, yl, clip_dur, keep & fold_a),
                              "fold_B": evaluate(st, plan_by_clip, yl, clip_dur, keep & ~fold_a),
                              "reached_target_on_A": bool(best_key[0])}
        print(size, json.dumps(res["vocab"][size]["fold_B"]), "target reached on A:", best_key[0], flush=True)
    Path(a.out).write_text(json.dumps(res, indent=1))


if __name__ == "__main__":
    main()
