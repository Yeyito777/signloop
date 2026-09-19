"""Ablations under signer-independent cross-validation. Every row = mean/std over test-signer folds.

    python -m recognition.ablate --synthetic --suite arch --folds 3 --out .runtime/ablate-arch.json

Interpretation rule (from the task): if a more complex variant does not beat the simpler one
on held-out signers, ship the simpler one. Differences smaller than the fold-to-fold std are noise.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import time

import numpy as np

from . import data as D
from .evaluate import TRACKING_STRESS, evaluate_model
from .train import TrainConfig, train

KEYS = ("known_top1", "raw_known_top1", "macro_f1", "far_show", "ece", "coverage", "precision")


def suite(name: str) -> list[tuple[str, dict]]:
    dual = "dual:concat"
    arch = [(a, {"arch": a}) for a in ("single_frame", "mlp", "gru", "tcn", "transformer", "stgcn", dual, "dual:gated", "dual:attention")]
    feats = [("dual/full", {}),
             ("dual/no-derivatives", {"features": {"derivatives": False}}),
             ("dual/shape-only (no trajectory stream)", {"features": {"motion": False, "derivatives": False}}),
             ("dual/no-angle-features", {"features": {"angles": False}}),
             ("dual/in-plane-rotation-normalized", {"features": {"rotate": True}})]
    reject = [("dual/background-class+policy", {}), ("dual/no-background (threshold on known-only model)", {"background": False})]
    off = lambda **kw: {"augment": kw}
    aug = [("aug/all-default", {}), ("aug/none", {"augment": {"p": 0.0}}),
           ("aug/no-landmark-dropout", off(landmark_dropout=False, frame_drop=False, joint_outliers=False)),
           ("aug/no-jitter", off(jitter=False)), ("aug/no-time-warp", off(time_warp=False)),
           ("aug/no-viewpoint+roll", off(viewpoint=False, roll=False)),
           ("aug/no-crop-pad", off(temporal_crop=False, temporal_pad=False)),
           ("aug/with-mirror", off(mirror=True))]
    return {"arch": arch, "features": feats, "reject": reject, "aug": aug,
            "all": arch + feats[1:] + reject[1:] + aug[1:]}[name]


def row(rep: dict) -> dict:
    o, c = rep["open_set"], rep["calibration"]
    cm = np.array(rep["raw_argmax"]["confusion"])
    k = cm.shape[0] - 1
    raw = float(np.trace(cm[:k, :k]) / max(cm[:k].sum(), 1))   # known signs, argmax, before any rejection
    return {"known_top1": rep["known_top1_after_rejection"], "raw_known_top1": raw, "macro_f1": rep["classification"]["macro_f1"],
            "far_show": o["false_accept_rate_show"], "ece": c["ece"], "coverage": o["coverage_show"],
            "precision": o["accepted_precision"]}


def run(samples, experiments, folds: int, base: TrainConfig, seeds=(0,), out: str | None = None, verbose=True):
    results = {}
    for fi, fold in enumerate(D.signer_folds(samples, folds, seed=0)):
        D.apply_fold(samples, fold)
        for name, over in experiments:
            for seed in seeds:
                cfg = TrainConfig(**{**base.__dict__, **over, "seed": seed})
                t = time.time()
                r = train(samples, cfg, verbose=False)
                clean = evaluate_model(r["model"], r["artifact"], samples)
                stress = evaluate_model(r["model"], r["artifact"], samples, corrupt=TRACKING_STRESS)
                results.setdefault(name, []).append({"fold": fi, "seed": seed, "clean": row(clean), "stress": row(stress),
                                                     "params": r["artifact"]["params"], "policy_can_show": clean["policy"]["tau_high"] != float("inf")})
                if verbose:
                    print(f"fold {fi} {name:55s} raw {row(clean)['raw_known_top1']:.3f} top1 {row(clean)['known_top1']:.3f} far {row(clean)['far_show']:.3f} "
                          f"stress-raw {row(stress)['raw_known_top1']:.3f} ({time.time() - t:.0f}s)", flush=True)
                if out:
                    Path(out).write_text(json.dumps(summarize(results), indent=2))
    return summarize(results)


def summarize(results: dict) -> dict:
    out = {}
    for name, rows in results.items():
        agg = {"n_runs": len(rows), "params": rows[0]["params"]}
        for view in ("clean", "stress"):
            agg[view] = {}
            for k in KEYS:
                v = np.array([r[view][k] for r in rows], dtype=float)
                v = v[~np.isnan(v)]
                agg[view][k] = {"mean": float(v.mean()), "std": float(v.std())} if len(v) else None
        out[name] = agg
    return out


def markdown(summary: dict) -> str:
    f = lambda d: "n/a" if d is None else f"{d['mean']:.3f}±{d['std']:.3f}"
    lines = ["| Variant | Params | Raw top-1 (no rejection) | Top-1 after rejection | Macro F1 | FAR | ECE | Stress raw top-1 | Stress FAR |",
             "|---|---|---|---|---|---|---|---|---|"]
    for name, a in summary.items():
        c, s = a["clean"], a["stress"]
        lines.append(f"| {name} | {a['params']:,} | {f(c['raw_known_top1'])} | {f(c['known_top1'])} | {f(c['macro_f1'])} | "
                     f"{f(c['far_show'])} | {f(c['ece'])} | {f(s['raw_known_top1'])} | {f(s['far_show'])} |")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus")
    ap.add_argument("--synthetic", action="store_true")
    ap.add_argument("--synthetic-signers", type=int, default=40)
    ap.add_argument("--suite", default="arch", choices=["arch", "features", "reject", "aug", "all"])
    ap.add_argument("--folds", type=int, default=4)
    ap.add_argument("--seeds", type=int, default=1)
    ap.add_argument("--epochs", type=int, default=25)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    if a.synthetic:
        from .synthetic import make_corpus
        samples = make_corpus(n_signers=a.synthetic_signers, per_class=4, per_neg=3, seed=0)["samples"]
    else:
        samples = D.load_corpus(a.corpus)["samples"]
    summary = run(samples, suite(a.suite), a.folds, TrainConfig(epochs=a.epochs, aug_versions=4), tuple(range(a.seeds)), a.out)
    Path(a.out).write_text(json.dumps(summary, indent=2))
    md = markdown(summary)
    Path(a.out).with_suffix(".md").write_text(md)
    print(md)


if __name__ == "__main__":
    main()
