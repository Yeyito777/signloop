"""Signer-independent evaluation. The test signers are touched here and only here.

Order of operations (no test-dependent choices anywhere):
  1. load model, temperature and prototypes from the checkpoint (fit on train/val signers)
  2. choose the rejection scorer by validation AUROC, derive tiers/thresholds on validation
  3. score the frozen decision rule once on the test signers
"""
from __future__ import annotations

import argparse
from collections import defaultdict
import json
from pathlib import Path
import time

import numpy as np
import torch

from . import data as D
from .augment import AugmentConfig, augment
from .features import FeatureConfig
from .metrics import (auroc, classification_report, coverage_accuracy, ece, per_group, reliability, softmax)
from .models import build_model
from .openset import Policy, Prototypes, SCORERS, compare_scorers, decide, derive_policy, scores
from .train import TrainConfig, predict, prepare


def load_artifact(path: str | Path):
    blob = torch.load(Path(path) / "model.pt", weights_only=False, map_location="cpu")
    model = build_model(blob["config"]["arch"], blob["n_out"])
    model.load_state_dict(blob["state"])
    model.eval()
    return model, {k: v for k, v in blob.items() if k != "state"}


def decisions_report(names: list[str], truth, pred, cal_conf, cal_correct, tier, samples, extra: dict | None = None) -> dict:
    """Metrics shared by every system (ours and the baseline) so the comparison is like for like.
    truth/pred are class indices into names (last = UNKNOWN). pred==UNKNOWN unless tier == 'show'."""
    truth, pred = np.asarray(truth), np.asarray(pred)
    cal_conf, cal_correct = np.asarray(cal_conf, float), np.asarray(cal_correct)
    k = len(names) - 1
    unk, known = truth == k, truth != k
    shown = np.array([t == "show" for t in tier])
    correct = pred == truth
    rep = classification_report(truth, pred, names)
    known_correct = float(correct[known].mean()) if known.any() else float("nan")
    out = {
        "n": int(len(truth)), "n_known": int(known.sum()), "n_unknown": int(unk.sum()),
        "classification": rep,
        "known_top1_after_rejection": known_correct,
        "open_set": {
            "false_accept_rate_show": float(shown[unk].mean()) if unk.any() else None,
            "false_accept_rate_show_or_retry": float(np.mean([t in ("show", "retry") for t, u in zip(tier, unk) if u])) if unk.any() else None,
            "known_rejected_rate": float((~shown[known]).mean()) if known.any() else None,
            "wrong_known_shown_rate": float((shown & known & ~correct)[known].mean()) if known.any() else None,
            "accepted_precision": float(correct[shown].mean()) if shown.any() else None,
            "coverage_show": float(shown.mean()),
            "retry_rate": float(np.mean([t == "retry" for t in tier])),
            "unknown_detection_precision": _ratio(((pred == k) & unk).sum(), (pred == k).sum()),
            "unknown_detection_recall": _ratio(((pred == k) & unk).sum(), unk.sum()),
        },
        # Calibration compares the model's own confidence with the model's own argmax correctness,
        # before the rejection policy. It answers "is 0.9 right 90% of the time?".
        "calibration": {"ece": ece(cal_conf, cal_correct), "reliability": reliability(cal_conf, cal_correct),
                        "coverage_accuracy": coverage_accuracy(cal_conf, cal_correct)},
    }
    signers = [s["signer"] for s in samples]
    out["per_signer"] = per_group(truth, pred, signers)
    accs = [v["accuracy"] for v in out["per_signer"].values()]
    out["per_signer_summary"] = {"min": float(min(accs)), "median": float(np.median(accs)), "max": float(max(accs))} if accs else {}
    kinds = defaultdict(list)
    for s, u, sh in zip(samples, unk, shown):
        if u:
            kinds[s.get("kind", "nonsign")].append(sh)
    out["false_accept_by_kind"] = {k_: {"n": len(v), "far": float(np.mean(v))} for k_, v in sorted(kinds.items())}
    for key in ("device", "lighting", "handedness", "distance", "background", "speed", "occlusion", "skin_tone_self_reported"):
        groups = [s.get(key, "") for s in samples]
        if len(set(groups)) > 1:
            out[f"accuracy_by_{key}"] = per_group(truth, pred, groups)
    if extra:
        out.update(extra)
    return out


def _ratio(a, b):
    return float(a) / float(b) if b else None


def latency_ms(model, stacked: dict, runs: int = 200) -> dict:
    """Single-sequence forward latency on this machine's CPU with torch. NOT an iPhone number."""
    model.eval()
    from .models import to_tensors
    one = {k: v[:1] for k, v in stacked.items() if k != "quality"}
    b = to_tensors(one, "cpu")
    ts = []
    with torch.no_grad():
        for i in range(runs + 10):
            t = time.perf_counter()
            model(b)
            if i >= 10:
                ts.append((time.perf_counter() - t) * 1000)
    return {"p50": float(np.percentile(ts, 50)), "p95": float(np.percentile(ts, 95)), "device": "host-cpu-torch"}


def evaluate_model(model, artifact: dict, samples: list[dict], far_high=0.05, far_low=0.20, scorer: str | None = None,
                   corrupt: AugmentConfig | None = None) -> dict:
    cfg = TrainConfig(**artifact["config"])
    labels, sets = prepare(samples, cfg, D.Labels(artifact["labels"][:-1]))
    fcfg = cfg.feature_cfg()
    if corrupt is not None:  # stress the TEST signers' tracking only; thresholds still come from clean validation
        rng = np.random.default_rng(12345)
        sets['test'].raw = [augment(r, corrupt, rng) for r in sets['test'].raw]
    names, k = labels.names, labels.k
    stacks = {sp: D.stack(sets[sp].features(fcfg)) for sp in ("val", "test")}
    T = artifact["temperature"]
    protos = Prototypes(np.array(artifact["prototypes"]["means"]), np.array(artifact["prototypes"]["inv_var"]))
    out = {}
    logits = {}
    emb = {}
    for sp in ("val", "test"):
        logits[sp], emb[sp] = predict(model, stacks[sp])
        if logits[sp].shape[1] == k:  # no background class: append a never-chosen UNKNOWN logit
            logits[sp] = np.concatenate([logits[sp], np.full((len(logits[sp]), 1), -1e4)], 1)
    yv, yt = sets["val"].y, sets["test"].y
    sep = compare_scorers(logits["val"], yv, k, T, emb["val"], protos)
    chosen = scorer or max(sep, key=lambda n: (np.nan_to_num(sep[n], nan=-1)))
    policy = derive_policy(chosen, logits["val"], yv, stacks["val"]["quality"], names[:-1], T, far_high, far_low,
                           emb["val"], protos)
    dec = decide(policy, logits["test"], stacks["test"]["quality"], emb["test"], protos)
    pred = np.array([d[0] for d in dec])
    tier = [d[1] for d in dec]
    cal_conf = softmax(logits["test"], T).max(1)
    cal_correct = logits["test"].argmax(1) == yt
    shown_pred = np.where(np.array([t == "show" for t in tier]), pred, k)
    rep = decisions_report(names, yt, shown_pred, cal_conf, cal_correct, tier, sets["test"].samples)
    # rejection scorers on test (reported, never used to choose anything)
    known_test = yt != k
    rep["scorer_auroc_test"] = {n: auroc(scores(n, logits["test"], T, emb["test"], protos)[known_test],
                                         scores(n, logits["test"], T, emb["test"], protos)[~known_test]) for n in SCORERS}
    rep["scorer_auroc_val"] = sep
    rep["raw_argmax"] = classification_report(yt, logits["test"].argmax(1), names)
    raw_conf_ece = ece(softmax(logits["test"], 1.0).max(1), cal_correct)
    rep["calibration"]["ece_uncalibrated_T1"] = raw_conf_ece
    rep["calibration"]["temperature"] = T
    rep["policy"] = policy.to_json()
    rep["chosen_scorer_by_val_auroc"] = chosen
    rep["runtime"] = {"params": artifact["params"], "latency": latency_ms(model, stacks["test"]),
                      "fp32_bytes": artifact["params"] * 4}
    rep["provenance"] = artifact["provenance"]
    rep["test_signers"] = sorted({s["signer"] for s in sets["test"].samples})
    return rep


def summary_row(name: str, rep: dict) -> dict:
    c = rep["classification"]
    o = rep["open_set"]
    return {"system": name, "known_top1": rep["known_top1_after_rejection"], "macro_f1": c["macro_f1"],
            "far_show": o["false_accept_rate_show"], "ece": rep["calibration"]["ece"],
            "coverage": o["coverage_show"], "precision": o["accepted_precision"]}


def markdown_table(rows: list[dict]) -> str:
    fmt = lambda v: "n/a" if v is None or (isinstance(v, float) and np.isnan(v)) else f"{v:.3f}"
    head = "| System | Known top-1 (after rejection) | Macro F1 | False-accept (unknown) | ECE | Coverage | Accepted precision |\n|---|---|---|---|---|---|---|\n"
    return head + "\n".join(f"| {r['system']} | {fmt(r['known_top1'])} | {fmt(r['macro_f1'])} | {fmt(r['far_show'])} | "
                            f"{fmt(r['ece'])} | {fmt(r['coverage'])} | {fmt(r['precision'])} |" for r in rows)


def confusion_markdown(rep: dict) -> str:
    c = rep["classification"]
    names = c["labels"]
    lines = ["| truth \\ pred | " + " | ".join(names) + " |", "|---|" + "---|" * len(names)]
    for n, row in zip(names, c["confusion"]):
        lines.append(f"| {n} | " + " | ".join(str(v) for v in row) + " |")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", required=True)
    ap.add_argument("--corpus")
    ap.add_argument("--synthetic", action="store_true")
    ap.add_argument("--split-seed", type=int, default=0)
    ap.add_argument("--out")
    args = ap.parse_args()
    model, art = load_artifact(args.run)
    if args.synthetic:
        from .synthetic import make_corpus
        corpus = make_corpus(seed=args.split_seed)
        D.assign_splits(corpus["samples"], args.split_seed)
    else:
        corpus = D.load_corpus(args.corpus)
    rep = evaluate_model(model, art, corpus["samples"])
    text = json.dumps(rep, indent=2, default=float)
    if args.out:
        Path(args.out).write_text(text)
    print(markdown_table([summary_row(Path(args.run).name, rep)]))
    print(confusion_markdown(rep))


if __name__ == "__main__":
    main()


# Tracking failures a phone actually produces, applied to test signers only.
TRACKING_STRESS = AugmentConfig(p=1.0, similarity=False, viewpoint=False, roll=False, time_warp=False,
                                temporal_crop=False, temporal_pad=False, jitter=True, jitter_sigma=0.05,
                                landmark_dropout=True, dropout_rate=0.12, frame_drop=True, frame_drop_rate=0.15,
                                joint_outliers=True, outlier_rate=0.08, anchor_dropout=False)
