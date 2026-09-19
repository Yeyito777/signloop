"""CURRENT BASELINE vs NEW MODELS on the exact same signer-disjoint test set.

    python -m recognition.benchmark --corpus corpus.json --out .runtime/bench          # real data
    python -m recognition.benchmark --synthetic --out .runtime/bench-synthetic         # pipeline check

Everything is trained/tuned on train+val signers; the test signers are read once per system.
Core ML size/latency are measured on this Mac (NOT an iPhone).
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import time

import numpy as np

from . import data as D
from .baselines import dtw_baseline
from .evaluate import confusion_markdown, evaluate_model, summary_row
from .train import TrainConfig, train


def build(samples, arch, epochs, seed, out):
    cfg = TrainConfig(arch=arch, epochs=epochs, seed=seed, aug_versions=6)
    r = train(samples, cfg, out_dir=out, verbose=False)
    rep = evaluate_model(r["model"], r["artifact"], samples)
    val_f1 = r["artifact"]["best_val_macro_f1"]
    return r, rep, val_f1


def coreml_stats(run_dir, samples, rep, export_dir, int8):
    try:
        from .export_coreml import export
        m = export(run_dir, export_dir, samples, rep["policy"], int8=int8)
        return {"package_kb": m["package_bytes"] / 1024, "latency_cpu_ms": m["latency_ms_mac_not_iphone"]["cpu_only"],
                "latency_all_ms": m["latency_ms_mac_not_iphone"]["all"], "parity": m["parity_vs_torch_fp32"],
                "precision": m["precision"], "shippable": m["shippable"]}
    except Exception as e:  # coremltools unavailable in this interpreter
        return {"error": f"{type(e).__name__}: {e}"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus")
    ap.add_argument("--synthetic", action="store_true")
    ap.add_argument("--synthetic-signers", type=int, default=32)
    ap.add_argument("--archs", nargs="+", default=["dual:concat", "gru"])
    ap.add_argument("--epochs", type=int, default=25)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--split-seed", type=int, default=0)
    ap.add_argument("--skip-baseline", action="store_true")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    if a.synthetic:
        from .synthetic import make_corpus
        samples = make_corpus(n_signers=a.synthetic_signers, per_class=4, per_neg=3, seed=0)["samples"]
        D.assign_splits(samples, a.split_seed)
    else:
        samples = D.load_corpus(a.corpus)["samples"]
        if any("split" not in s for s in samples):
            D.assign_splits(samples, a.split_seed)
    D.assert_no_leakage(samples)
    result = {"dataset": "SYNTHETIC (pipeline check, not ASL)" if a.synthetic else str(a.corpus),
              "test_signers": sorted({s["signer"] for s in samples if s["split"] == "test"}),
              "n_test": sum(s["split"] == "test" for s in samples), "systems": {}}
    rows = []
    if not a.skip_baseline:
        t = time.time()
        rep = dtw_baseline(samples)
        result["systems"]["current: reference-dtw-v2"] = rep
        rows.append(summary_row("current: reference-dtw-v2", rep))
        print(f"baseline done {time.time() - t:.0f}s", flush=True)
    best = None
    for arch in a.archs:
        run = out / f"run-{arch.replace(':', '-')}"
        r, rep, val_f1 = build(samples, arch, a.epochs, a.seed, run)
        rep["coreml_fp16"] = coreml_stats(run, samples, rep, out / f"export-{arch.replace(':', '-')}", False)
        rep["coreml_int8"] = coreml_stats(run, samples, rep, out / f"export-{arch.replace(':', '-')}-int8", True)
        name = f"new: {arch}"
        result["systems"][name] = rep
        rows.append(summary_row(name, rep))
        if best is None or val_f1 > best[0]:
            best = (val_f1, name)
        print(f"{name} done val_macro_f1={val_f1:.3f}", flush=True)
    result["best_new_by_validation_macro_f1"] = best[1] if best else None
    (out / "benchmark.json").write_text(json.dumps(result, indent=2, default=float))
    from .evaluate import markdown_table
    md = [markdown_table(rows), ""]
    for name in result["systems"]:
        rep = result["systems"][name]
        md += [f"### {name}", confusion_markdown(rep), ""]
        if "coreml_fp16" in rep:
            md.append(f"Core ML fp16: {json.dumps(rep['coreml_fp16'])}\n\nCore ML int8: {json.dumps(rep['coreml_int8'])}\n")
    (out / "benchmark.md").write_text("\n".join(md))
    print("\n".join(md[:1]))


if __name__ == "__main__":
    main()
