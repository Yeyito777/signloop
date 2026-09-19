"""Reproducible training. `python -m recognition.train --help`

Design points:
  * Splits are by signer and asserted leak-free before any training.
  * The validation signers are the ONLY data used for early stopping, temperature fitting and
    threshold selection. Test signers are read once, by recognition.evaluate.
  * Augmentation acts on landmarks; features are recomputed. A fixed-size bank of augmented
    feature sets is built in parallel and sampled per epoch (dominant cost is numpy featurization).
  * Everything random derives from --seed.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ProcessPoolExecutor
import multiprocessing
from dataclasses import asdict, dataclass, field, fields
import json
import os
from pathlib import Path
import random
import time

import numpy as np
import torch
from torch import nn
import torch.nn.functional as Fn

from . import data as D
from .augment import AugmentConfig, NONE, augment
from .features import FeatureConfig, featurize
from .metrics import classification_report, fit_temperature
from .models import build_model, count_params, to_tensors
from .openset import fit_prototypes


@dataclass
class TrainConfig:
    arch: str = "dual:concat"
    seed: int = 0
    epochs: int = 40
    batch: int = 32
    lr: float = 2e-3
    weight_decay: float = 1e-2
    label_smoothing: float = 0.05
    focal_gamma: float = 0.0            # 0 = cross-entropy; >0 focal loss for confusable/imbalanced classes
    class_balance: bool = True
    background: bool = True             # train an explicit UNKNOWN class on hard negatives
    neg_weight: float = 1.0
    patience: int = 8
    aug_versions: int = 8
    workers: int = 0                    # 0 = min(8, cpu)
    device: str = "cpu"
    features: dict = field(default_factory=dict)
    augment: dict = field(default_factory=dict)

    def feature_cfg(self) -> FeatureConfig:
        return FeatureConfig(**self.features)

    def augment_cfg(self) -> AugmentConfig:
        return AugmentConfig(**self.augment)


def seed_everything(seed: int):
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)


def _feat_job(args):
    raw, fcfg, acfg, seed = args
    rng = np.random.default_rng(seed)
    return featurize(augment(raw, acfg, rng), fcfg)


def build_bank(seq: D.SequenceSet, fcfg, acfg, versions: int, seed: int, workers: int):
    """versions augmented feature sets + 1 clean copy per sample -> list of stacked dicts."""
    workers = workers or min(8, os.cpu_count() or 1)
    jobs = [[(r, fcfg, acfg, seed * 1_000_003 + v * 10_007 + i) for i, r in enumerate(seq.raw)] for v in range(versions)]
    bank = []
    if workers > 1 and len(seq) * versions > 200:
        # fork: workers only run numpy featurization on already-loaded arrays (no torch state is used)
        with ProcessPoolExecutor(workers, mp_context=multiprocessing.get_context("fork")) as pool:
            for batch in jobs:
                bank.append(D.stack(list(pool.map(_feat_job, batch, chunksize=16))))
    else:
        for batch in jobs:
            bank.append(D.stack([_feat_job(a) for a in batch]))
    return bank


def batches(stacked: dict, y: np.ndarray, size: int, rng: np.random.Generator | None):
    n = len(y)
    order = rng.permutation(n) if rng is not None else np.arange(n)
    for i in range(0, n, size):
        idx = order[i:i + size]
        yield {k: v[idx] for k, v in stacked.items() if k != "quality"}, y[idx]


def loss_fn(logits, y, weights, smoothing, gamma):
    logp = Fn.log_softmax(logits, -1)
    n = logits.shape[-1]
    with torch.no_grad():
        t = torch.full_like(logp, smoothing / max(n - 1, 1))
        t.scatter_(1, y[:, None], 1 - smoothing)
    nll = -(t * logp).sum(1)
    if gamma > 0:
        p = logp.gather(1, y[:, None])[:, 0].exp()
        nll = nll * (1 - p) ** gamma
    w = weights[y]
    return (nll * w).sum() / w.sum()


@torch.no_grad()
def predict(model: nn.Module, stacked: dict, device="cpu", size: int = 128):
    model.eval()
    logits, emb = [], []
    n = len(stacked["nodes"])
    for i in range(0, n, size):
        b = to_tensors({k: v[i:i + size] for k, v in stacked.items() if k != "quality"}, device)
        out = model(b)
        logits.append(out["logits"].float().cpu().numpy())
        emb.append(out["emb"].float().cpu().numpy())
    return np.concatenate(logits), np.concatenate(emb)


def prepare(samples: list[dict], cfg: TrainConfig, labels: D.Labels | None = None):
    """Split by signer, verify no leakage, build train/val/test SequenceSets."""
    D.assert_no_leakage(samples)
    labels = labels or D.Labels.from_samples([s for s in samples if s["split"] == "train"])
    sets = {sp: D.SequenceSet(D.subset(samples, sp), labels) for sp in ("train", "val", "test")}
    if not cfg.background:
        keep = np.flatnonzero(sets["train"].y != labels.k)
        s = sets["train"]
        s.samples = [s.samples[i] for i in keep]
        s.raw = [s.raw[i] for i in keep]
        s.y = s.y[keep]
    return labels, sets


def train(samples: list[dict], cfg: TrainConfig, out_dir: str | Path | None = None, verbose: bool = True) -> dict:
    seed_everything(cfg.seed)
    labels, sets = prepare(samples, cfg)
    n_out = labels.k + (1 if cfg.background else 0)
    fcfg, acfg = cfg.feature_cfg(), cfg.augment_cfg()
    train_set, val_set = sets["train"], sets["val"]
    if len(train_set) == 0 or len(val_set) == 0:
        raise D.CorpusError("training and validation splits must be nonempty")
    t0 = time.time()
    bank = [D.stack(train_set.features(fcfg))] + build_bank(train_set, fcfg, acfg, cfg.aug_versions, cfg.seed, cfg.workers)
    val_stack = D.stack(val_set.features(fcfg))
    if verbose:
        print(f"features: train={len(train_set)} val={len(val_set)} bank={len(bank)} in {time.time() - t0:.1f}s")
    y = train_set.y
    device = torch.device(cfg.device)
    model = build_model(cfg.arch, n_out).to(device)
    counts = np.bincount(y, minlength=n_out).astype(np.float32)
    w = (counts.sum() / np.maximum(counts, 1) / n_out) if cfg.class_balance else np.ones(n_out, np.float32)
    if cfg.background:
        w[labels.k] *= cfg.neg_weight
    weights = torch.tensor(w, device=device)
    opt = torch.optim.AdamW(model.parameters(), lr=cfg.lr, weight_decay=cfg.weight_decay)
    steps = cfg.epochs * int(np.ceil(len(y) / cfg.batch))
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=cfg.lr, total_steps=steps, pct_start=0.15)
    rng = np.random.default_rng(cfg.seed)
    best, best_state, bad, history = (-1.0, np.inf), None, 0, []
    # Without a background class UNKNOWN validation samples cannot be scored; use known ones only.
    vm = np.ones(len(val_set.y), bool) if cfg.background else val_set.y < labels.k
    for epoch in range(cfg.epochs):
        model.train()
        stacked = bank[int(rng.integers(len(bank)))]
        total = 0.0
        for xb, yb in batches(stacked, y, cfg.batch, rng):
            out = model(to_tensors(xb, device))
            loss = loss_fn(out["logits"], torch.as_tensor(yb, device=device), weights, cfg.label_smoothing, cfg.focal_gamma)
            opt.zero_grad()
            loss.backward()
            nn.utils.clip_grad_norm_(model.parameters(), 2.0)
            opt.step()
            sched.step()
            total += loss.item() * len(yb)
        logits, _ = predict(model, val_stack, device)
        pred = logits.argmax(1)
        f1 = classification_report(val_set.y[vm], pred[vm], labels.names)["macro_f1"]
        vloss = float(Fn.cross_entropy(torch.as_tensor(logits[vm]), torch.as_tensor(val_set.y[vm])))
        history.append({"epoch": epoch, "train_loss": total / len(y), "val_loss": vloss, "val_macro_f1": f1})
        if verbose and (epoch % 5 == 0 or epoch == cfg.epochs - 1):
            print(f"epoch {epoch:3d} loss {total / len(y):.3f} val_loss {vloss:.3f} val_f1 {f1:.3f}")
        if (f1, -vloss) > (best[0], -best[1]):
            best, bad = (f1, vloss), 0
            best_state = {k: v.detach().cpu().clone() for k, v in model.state_dict().items()}
        else:
            bad += 1
            if bad >= cfg.patience:
                break
    model.load_state_dict(best_state)
    val_logits, val_emb = predict(model, val_stack, device)
    train_logits, train_emb = predict(model, bank[0], device)
    known_idx = y < labels.k
    artifact = {
        "config": asdict(cfg), "labels": labels.names, "n_out": n_out, "background": cfg.background,
        "temperature": fit_temperature(val_logits[vm], val_set.y[vm]),
        "prototypes": fit_prototypes(train_emb[known_idx], y[known_idx], labels.k).to_json(),
        "params": count_params(model), "history": history, "best_val_macro_f1": best[0], "seed": cfg.seed,
        "provenance": D.provenance(samples),
        "skipped": {sp: s.skipped for sp, s in sets.items() if s.skipped},
        "train_seconds": time.time() - t0,
    }
    if out_dir:
        out = Path(out_dir)
        out.mkdir(parents=True, exist_ok=True)
        torch.save({"state": model.state_dict(), **artifact}, out / "model.pt")
        (out / "config.json").write_text(json.dumps(artifact["config"], indent=2))
        (out / "train_log.json").write_text(json.dumps({k: v for k, v in artifact.items() if k != "config"}, indent=2, default=float))
    return {"model": model, "labels": labels, "sets": sets, "artifact": artifact, "val": (val_logits, val_emb, val_stack)}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--corpus", help="version-1 corpus JSON (see recognition.data)")
    ap.add_argument("--synthetic", action="store_true", help="PIPELINE CHECK ONLY: synthetic non-ASL data")
    ap.add_argument("--config", help="JSON file with TrainConfig fields")
    ap.add_argument("--out", required=True)
    ap.add_argument("--split-seed", type=int, default=0)
    ap.add_argument("--assign-splits", action="store_true", help="assign signer-level splits (ignore existing)")
    for f in fields(TrainConfig):
        if f.type in ("int", "float", "str"):
            ap.add_argument(f"--{f.name.replace('_', '-')}", type=type(f.default), default=None)
    args = ap.parse_args()
    cfg = TrainConfig(**json.loads(Path(args.config).read_text())) if args.config else TrainConfig()
    for f in fields(TrainConfig):
        v = getattr(args, f.name, None)
        if v is not None:
            setattr(cfg, f.name, v)
    if args.synthetic:
        from .synthetic import make_corpus
        corpus = make_corpus(seed=args.split_seed)
    elif args.corpus:
        corpus = D.load_corpus(args.corpus)
    else:
        ap.error("need --corpus or --synthetic")
    if args.assign_splits or args.synthetic or any("split" not in s for s in corpus["samples"]):
        D.assign_splits(corpus["samples"], args.split_seed)
    train(corpus["samples"], cfg, args.out)


if __name__ == "__main__":
    main()
