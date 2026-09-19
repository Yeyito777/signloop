"""Trained checkpoint -> Core ML package + policy.json for the Swift engine.

    python -m recognition.export_coreml --run runs/x --out ios/Signloop/Resources/SignEngine [--int8]

Outputs
    SignEngine.mlpackage   fixed-shape (batch 1, T steps) float16 ML Program
    policy.json            labels, feature config, segmenter config, temperature, thresholds, prototypes
    manifest.json          SHA-256, param count, training provenance, parity + latency numbers, `shippable`

`shippable` is true only if every training sample was documented as redistributable. The app
must refuse to load a package whose manifest says otherwise. Latency measured here is a Mac number
(Apple M-series); it is not an iPhone measurement.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import time

import numpy as np
import torch

from .features import FeatureConfig, GLOBAL_WIDTH, N_META, N_MOTION
from .segmenter import SegmenterConfig

INPUTS = ("nodes", "glob", "motion", "mask", "meta")


class Wrapper(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, nodes, glob, motion, mask, meta):
        out = self.model({"nodes": nodes, "glob": glob, "motion": motion, "mask": mask, "meta": meta})
        return out["logits"], out["emb"]


def shapes(steps: int) -> dict:
    return {"nodes": (1, steps, 2, 21, 6), "glob": (1, steps, 2, GLOBAL_WIDTH), "motion": (1, steps, N_MOTION),
            "mask": (1, steps, 3), "meta": (1, N_META)}


def convert(model, steps: int, int8: bool = False):
    import coremltools as ct
    model.eval()
    example = tuple(torch.zeros(shapes(steps)[k]) for k in INPUTS)
    # Fixed shapes: torch.export bakes them in (the TorchScript trace leaks dynamic size casts that
    # coremltools cannot lower).
    exported = torch.export.export(Wrapper(model).eval(), example).run_decompositions({})
    ml = ct.convert(exported, convert_to="mlprogram", minimum_deployment_target=ct.target.iOS17,
                    compute_precision=ct.precision.FLOAT16,
                    inputs=[ct.TensorType(name=k, shape=shapes(steps)[k]) for k in INPUTS],
                    outputs=[ct.TensorType(name="logits"), ct.TensorType(name="emb")])
    if int8:
        import coremltools.optimize.coreml as cto
        cfg = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8"))
        ml = cto.linear_quantize_weights(ml, cfg)
    return ml


def parity(model, ml, stacked: dict, n: int = 64) -> dict:
    """Torch fp32 vs Core ML (fp16 / int8): logit error and decision agreement."""
    import coremltools as ct
    diffs, agree = [], []
    for i in range(min(n, len(stacked["nodes"]))):
        feed = {k: stacked[k][i:i + 1].astype(np.float32) for k in INPUTS}
        with torch.no_grad():
            ref = model({k: torch.as_tensor(v) for k, v in feed.items()})["logits"][0].numpy()
        got = np.asarray(ml.predict(feed)["logits"]).reshape(-1)
        diffs.append(float(np.abs(ref - got).max()))
        agree.append(int(ref.argmax() == got.argmax()))
    return {"samples": len(diffs), "max_abs_logit_diff": float(max(diffs)), "median_abs_logit_diff": float(np.median(diffs)),
            "argmax_agreement": float(np.mean(agree))}


def latency(pkg: Path, stacked: dict, runs: int = 200) -> dict:
    """Median/p95 single-inference latency per compute-unit setting on THIS Mac (not an iPhone)."""
    import coremltools as ct
    feed = {k: stacked[k][:1].astype(np.float32) for k in INPUTS}
    out = {}
    for name, units in (("cpu_only", ct.ComputeUnit.CPU_ONLY), ("all", ct.ComputeUnit.ALL)):
        model = ct.models.MLModel(str(pkg), compute_units=units)
        ts = []
        for i in range(runs + 10):
            t = time.perf_counter()
            model.predict(feed)
            if i >= 10:
                ts.append((time.perf_counter() - t) * 1000)
        out[name] = {"p50": float(np.percentile(ts, 50)), "p95": float(np.percentile(ts, 95))}
    return out


def _finite(o):
    """Strict JSON has no Infinity; the Swift decoder reads "inf"/"-inf" strings."""
    if isinstance(o, float) and o in (float("inf"), float("-inf")):
        return "inf" if o > 0 else "-inf"
    if isinstance(o, dict):
        return {k: _finite(v) for k, v in o.items()}
    if isinstance(o, (list, tuple)):
        return [_finite(v) for v in o]
    return o


def sha256_dir(path: Path) -> str:
    h = hashlib.sha256()
    for f in sorted(p for p in path.rglob("*") if p.is_file()):
        h.update(str(f.relative_to(path)).encode())
        h.update(f.read_bytes())
    return h.hexdigest()


def export(run_dir: str | Path, out_dir: str | Path, samples: list[dict], policy: dict, int8: bool = False,
           seg_cfg: SegmenterConfig = SegmenterConfig()) -> dict:
    import coremltools as ct
    from . import data as D
    from .evaluate import load_artifact
    from .train import TrainConfig, prepare
    model, art = load_artifact(run_dir)
    cfg = TrainConfig(**art["config"])
    fcfg = cfg.feature_cfg()
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    ml = convert(model, fcfg.steps, int8)
    pkg = out / "SignEngine.mlpackage"
    ml.save(str(pkg))
    labels, sets = prepare(samples, cfg, D.Labels(art["labels"][:-1]))
    stacked = D.stack(sets["test"].features(fcfg))
    loaded = ct.models.MLModel(str(pkg))
    try:
        D.assert_shippable(samples)
        shippable, why = True, ""
    except D.CorpusError as e:
        shippable, why = False, str(e)
    manifest = {"model_sha256": sha256_dir(pkg), "params": art["params"], "arch": cfg.arch, "int8": int8,
                "precision": "float16" + ("+int8-weights" if int8 else ""), "steps": fcfg.steps,
                "labels": art["labels"], "provenance": art["provenance"], "shippable": shippable, "not_shippable_reason": why,
                "parity_vs_torch_fp32": parity(model, loaded, stacked), "latency_ms_mac_not_iphone": latency(pkg, stacked),
                "package_bytes": sum(f.stat().st_size for f in pkg.rglob("*") if f.is_file())}
    policy_doc = {"policy": policy, "feature": fcfg.__dict__, "segmenter": seg_cfg.__dict__, "labels": art["labels"],
                  "prototypes": art["prototypes"], "schema": 1}
    (out / "policy.json").write_text(json.dumps(_finite(policy_doc), indent=2))
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2))
    return manifest


def main():
    from . import data as D
    from .evaluate import evaluate_model, load_artifact
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--corpus")
    ap.add_argument("--synthetic", action="store_true")
    ap.add_argument("--int8", action="store_true")
    ap.add_argument("--split-seed", type=int, default=0)
    a = ap.parse_args()
    if a.synthetic:
        from .synthetic import make_corpus
        corpus = make_corpus(n_signers=32, per_class=4, per_neg=3, seed=a.split_seed)
        D.assign_splits(corpus["samples"], a.split_seed)
    else:
        corpus = D.load_corpus(a.corpus)
    model, art = load_artifact(a.run)
    rep = evaluate_model(model, art, corpus["samples"])
    print(json.dumps(export(a.run, a.out, corpus["samples"], rep["policy"], a.int8), indent=2))


if __name__ == "__main__":
    main()
