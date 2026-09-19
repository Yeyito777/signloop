"""Corpus loading, signer-independent splitting, leakage checks, provenance gating.

Corpus format = the repo's version-1 corpus (see docs/recognition-evaluation.md) with
optional extra per-sample metadata that we keep and report on:
  id, label, signer, source, split, session, device, lighting, handedness, fps,
  duration_ms, kind (for UNKNOWN: rest/random_motion/transition/unsupported_shape/
  incomplete/incorrect/nonsign), license, redistribution ("ALLOWED" | "PROHIBITED" | ...).

A random clip-level split is never offered. Everything is split by signer.
"""
from __future__ import annotations

from collections import defaultdict
import hashlib
import json
from pathlib import Path

import numpy as np

from .features import FeatureConfig, FeatureError, RawSequence, featurize, frames_to_raw

UNKNOWN = "UNKNOWN"
REQUIRED = ("id", "label", "signer", "source", "frames")


class CorpusError(ValueError):
    pass


def load_corpus(path: str | Path, max_bytes: int = 500_000_000) -> dict:
    path = Path(path)
    if path.stat().st_size > max_bytes:
        raise CorpusError("corpus too large")
    data = json.loads(path.read_text())
    return validate_corpus(data)


def validate_corpus(data: dict) -> dict:
    if data.get("version") != 1 or not isinstance(data.get("samples"), list):
        raise CorpusError("expected version-1 corpus with samples")
    seen = set()
    for s in data["samples"]:
        for key in REQUIRED:
            if key not in s or (isinstance(s[key], str) and not s[key].strip()):
                raise CorpusError(f"sample missing {key}: {s.get('id')}")
        if s["id"] in seen:
            raise CorpusError(f"duplicate id {s['id']}")
        seen.add(s["id"])
        s.setdefault("session", f"{s['signer']}-s0")
        s.setdefault("license", "unspecified")
        s.setdefault("redistribution", "UNKNOWN")
        s.setdefault("kind", "sign" if s["label"] != UNKNOWN else "nonsign")
        if s["split"] if "split" in s else False:
            if s["split"] == "calibration":
                s["split"] = "val"
            if s["split"] not in ("train", "val", "test"):
                raise CorpusError(f"bad split {s['split']}")
    return data


def signer_hash(signer: str, seed: int) -> float:
    h = hashlib.sha256(f"{seed}:{signer}".encode()).digest()
    return int.from_bytes(h[:8], "big") / 2 ** 64


def assign_splits(samples: list[dict], seed: int = 0, fractions=(0.6, 0.2, 0.2), min_signers=3) -> None:
    """Deterministic signer-level assignment (train/val/test). Mutates samples['split'].
    Signers are ordered by hash and cut by count, so each split gets at least one when possible."""
    signers = sorted({s["signer"] for s in samples}, key=lambda x: signer_hash(x, seed))
    n = len(signers)
    if n < min_signers:
        raise CorpusError(f"need >= {min_signers} signers for signer-independent evaluation, have {n}")
    n_test = max(1, round(n * fractions[2]))
    n_val = max(1, round(n * fractions[1]))
    test, val = set(signers[:n_test]), set(signers[n_test:n_test + n_val])
    for s in samples:
        s["split"] = "test" if s["signer"] in test else "val" if s["signer"] in val else "train"


def signer_folds(samples: list[dict], k: int = 5, seed: int = 0):
    """GroupKFold over signers. Yields dict(train, val, test) sample-id lists. For fold i the
    test signers are fold i, validation signers are fold i+1 (used only for early stopping,
    calibration and threshold selection), and training is everything else."""
    signers = sorted({s["signer"] for s in samples}, key=lambda x: signer_hash(x, seed))
    if len(signers) < 3:
        raise CorpusError("need >= 3 signers")
    k = min(k, len(signers))
    folds = [signers[i::k] for i in range(k)]
    for i in range(k):
        test, val = set(folds[i]), set(folds[(i + 1) % k]) if k > 1 else set()
        yield _fold(samples, test, val)


def leave_one_signer_out(samples: list[dict], seed: int = 0):
    signers = sorted({s["signer"] for s in samples}, key=lambda x: signer_hash(x, seed))
    for i, test in enumerate(signers):
        val = signers[(i + 1) % len(signers)]
        yield _fold(samples, {test}, {val})


def _fold(samples, test, val):
    out = defaultdict(list)
    for s in samples:
        out["test" if s["signer"] in test else "val" if s["signer"] in val else "train"].append(s["id"])
    return dict(out)


def apply_fold(samples: list[dict], fold: dict) -> None:
    where = {i: name for name, ids in fold.items() for i in ids}
    for s in samples:
        s["split"] = where[s["id"]]


def geometry_digest(sample: dict) -> str:
    t0 = sample["frames"][0]["timestampMS"]
    canonical = [{"h": f["hands"], "t": f["timestampMS"] - t0} for f in sample["frames"]]
    return hashlib.sha256(json.dumps(canonical, sort_keys=True).encode()).hexdigest()


def assert_no_leakage(samples: list[dict]) -> None:
    """Fail loudly on signer, session or duplicate-geometry overlap across splits."""
    by_signer, by_session, digests = defaultdict(set), defaultdict(set), {}
    for s in samples:
        by_signer[s["signer"]].add(s["split"])
        by_session[s["session"]].add(s["split"])
        if any(f["hands"] for f in s["frames"]):
            d = geometry_digest(s)
            if d in digests and digests[d] != s["split"]:
                raise CorpusError(f"identical recording appears in {digests[d]} and {s['split']}: {s['id']}")
            digests.setdefault(d, s["split"])
    for name, groups in (("signer", by_signer), ("session", by_session)):
        for key, splits in groups.items():
            if len(splits) > 1:
                raise CorpusError(f"{name} {key!r} occurs in multiple splits: {sorted(splits)}")


def assert_shippable(samples: list[dict]) -> None:
    """A model whose TRAINING data is not documented as redistributable must not be bundled."""
    bad = sorted({(s["source"], s["license"], s["redistribution"]) for s in samples
                  if s["split"] == "train" and s["redistribution"] != "ALLOWED"})
    if bad:
        raise CorpusError("training data is not cleared for redistribution: " + "; ".join(map(str, bad)))


def provenance(samples: list[dict]) -> dict:
    """Aggregate provenance recorded inside every checkpoint."""
    out = defaultdict(int)
    for s in samples:
        if s["split"] == "train":
            out[(s["source"], s["license"], s["redistribution"])] += 1
    return [{"source": a, "license": b, "redistribution": c, "train_samples": n} for (a, b, c), n in sorted(out.items())]


class Labels:
    """Known classes in stable order followed by the background/UNKNOWN class."""

    def __init__(self, known: list[str]):
        self.known = list(known)
        self.names = self.known + [UNKNOWN]

    @staticmethod
    def from_samples(samples):
        return Labels(sorted({s["label"] for s in samples if s["label"] != UNKNOWN}))

    @property
    def k(self) -> int:
        return len(self.known)

    def index(self, label: str) -> int:
        return self.k if label == UNKNOWN else self.known.index(label)


class SequenceSet:
    """Raw sequences + metadata for a list of samples. Featurization is deferred so
    augmentation can act on landmarks before features are recomputed."""

    def __init__(self, samples: list[dict], labels: Labels):
        self.samples, self.labels, self.raw, self.y = [], labels, [], []
        self.skipped = []
        for s in samples:
            try:
                raw = frames_to_raw(s["frames"])
                if raw.n < 2 or not raw.present.any():
                    raise FeatureError("no hand observations")
            except FeatureError as e:
                self.skipped.append((s["id"], str(e)))
                continue
            self.samples.append(s)
            self.raw.append(raw)
            self.y.append(labels.index(s["label"]))
        self.y = np.array(self.y, dtype=np.int64)

    def __len__(self):
        return len(self.samples)

    def features(self, cfg: FeatureConfig):
        return [featurize(r, cfg) for r in self.raw]

    def meta(self, key):
        return np.array([s.get(key, "") for s in self.samples])


def subset(samples: list[dict], split: str) -> list[dict]:
    return [s for s in samples if s.get("split") == split]


def stack(features) -> dict:
    return {"nodes": np.stack([f.nodes for f in features]), "glob": np.stack([f.glob for f in features]),
            "motion": np.stack([f.motion for f in features]), "mask": np.stack([f.mask for f in features]),
            "meta": np.stack([f.meta for f in features]),
            "quality": np.array([f.tracking_quality for f in features], dtype=np.float32)}
