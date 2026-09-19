"""Open-set rejection: scoring, threshold selection from validation signers, and tiers.

Product rule: saying "not sure" is much cheaper than speaking a wrong sign, so thresholds
are chosen to bound the *false-accept rate on unknown input* (with a small-sample-safe upper
bound), not to maximize accuracy. Nothing here uses test data.

  score >= tau_high                 -> SHOW (present for user confirmation)
  tau_low <= score < tau_high       -> RETRY (uncertain; ask the signer to repeat)
  score <  tau_low or quality gate  -> UNKNOWN
"""
from __future__ import annotations

from dataclasses import dataclass, asdict

import numpy as np

from .metrics import auroc, softmax, wilson_upper

SCORERS = ["log_odds", "max_prob", "entropy", "margin", "energy", "prototype"]


def scores(name: str, logits: np.ndarray, T: float = 1.0, emb=None, protos=None) -> np.ndarray:
    """Higher = more likely a supported sign. logits is (N, K+1) with the last column UNKNOWN,
    or (N, K) for a model with no background class."""
    logits = np.asarray(logits, float)
    p = softmax(logits, T)
    if name == "log_odds":
        # Log-odds of the top KNOWN class against everything else (incl. UNKNOWN). Monotone in
        # max_prob but does not saturate at 1.0, so ranking (and thresholds) survive confident models.
        z = logits / T
        kn = z[:, :-1] if logits.shape[1] > 2 else z
        top = kn.max(1)
        rest = np.where(z == top[:, None], -np.inf, z)
        m = np.max(rest, axis=1)
        return top - (m + np.log(np.exp(rest - m[:, None]).sum(1)))
    if name == "max_prob":
        return p[:, :-1].max(1) if logits.shape[1] > 2 else p.max(1)
    if name == "entropy":
        return 1.0 + (p * np.log(np.clip(p, 1e-12, 1))).sum(1) / np.log(p.shape[1])
    if name == "margin":
        s = np.sort(p, axis=1)
        return s[:, -1] - s[:, -2]
    if name == "energy":
        z = logits[:, :-1] / T
        m = z.max(1)
        return T * (m + np.log(np.exp(z - m[:, None]).sum(1)))
    if name == "prototype":
        return -prototype_distance(emb, protos)
    raise KeyError(name)


@dataclass
class Prototypes:
    means: np.ndarray       # (K, E)
    inv_var: np.ndarray     # (E,) shared diagonal covariance

    def to_json(self):
        return {"means": self.means.tolist(), "inv_var": self.inv_var.tolist()}


def fit_prototypes(emb: np.ndarray, y: np.ndarray, k: int) -> Prototypes:
    means = np.stack([emb[y == c].mean(0) if (y == c).any() else np.zeros(emb.shape[1]) for c in range(k)])
    res = np.concatenate([emb[y == c] - means[c] for c in range(k) if (y == c).any()])
    return Prototypes(means, 1.0 / (res.var(0) + 1e-3))


def prototype_distance(emb: np.ndarray, protos: Prototypes) -> np.ndarray:
    d = ((emb[:, None, :] - protos.means[None]) ** 2 * protos.inv_var).sum(-1)
    return d.min(1) / emb.shape[1]


@dataclass
class Policy:
    """Everything the app needs to turn a model output into a user-visible decision."""
    scorer: str
    temperature: float
    tau_high: float
    tau_low: float
    quality_min: float
    known: list[str]
    target_far_high: float
    target_far_low: float
    reference_n: int = 0          # validation samples that could be falsely accepted (unknown + wrong-known)
    min_reference_n: int = 0      # zero-error samples needed before target_far_high is even reachable

    @property
    def can_show(self) -> bool:
        return self.tau_high != float("inf")

    def to_json(self):
        return asdict(self)


def _feasible(score, is_bad, tau_far, n_unknown_ref):
    """Smallest tau whose (Wilson-upper) bad-accept rate on unknown validation samples <= tau_far."""
    cands = np.unique(np.concatenate([score, [np.inf]]))
    for tau in cands:
        k = int(((score >= tau) & is_bad).sum())
        if wilson_upper(k, n_unknown_ref) <= tau_far:
            return float(tau)
    return float("inf")


def derive_policy(name: str, val_logits, val_y, val_quality, known: list[str], T: float,
                  far_high: float = 0.05, far_low: float = 0.20, emb=None, protos=None,
                  max_cost: float = 0.02) -> Policy:
    """Derive thresholds from validation signers only.

    A sample is a *bad accept* if it is UNKNOWN but scored as known, or a known sign whose
    argmax is a different known sign. far_* bounds the Wilson upper confidence limit of the
    bad-accept rate on validation samples, so tiny validation sets yield conservative (even
    infinite = always-unknown) thresholds instead of optimistic ones."""
    k = len(known)
    s = scores(name, val_logits, T, emb, protos)
    pred = np.asarray(val_logits).argmax(1)
    y = np.asarray(val_y)
    unknown = y == k
    bad = (unknown & (pred != k)) | (~unknown & (pred != y) & (pred != k))
    reference = max(int(unknown.sum()) + int((~unknown & (pred != y)).sum()), 1)
    tau_high = _feasible(s, bad & (pred != k), far_high, reference)
    tau_low = min(_feasible(s, bad & (pred != k), far_low, reference), tau_high)
    good = (~unknown) & (pred == y)
    q = np.asarray(val_quality)
    grid = np.unique(np.round(np.linspace(0, 0.9, 19), 2))
    q_min = 0.0
    for cand in grid:
        if good.any() and float((good & (q < cand)).sum() / good.sum()) <= max_cost:
            q_min = float(cand)
    # zero bad accepts still leaves a Wilson upper bound of z^2/(n+z^2); n must exceed z^2(1/far-1)
    need = int(np.ceil(1.96 ** 2 * (1 / far_high - 1)))
    return Policy(name, float(T), tau_high, tau_low, q_min, list(known), far_high, far_low, reference, need)


def decide(policy: Policy, logits, quality, emb=None, protos=None):
    """-> (label_index or K for UNKNOWN, tier str, score). Tiers: show / retry / unknown / low_tracking."""
    logits = np.atleast_2d(np.asarray(logits, float))
    k = len(policy.known)
    s = scores(policy.scorer, logits, policy.temperature, emb, protos)
    pred = logits.argmax(1)
    out = []
    for i in range(len(s)):
        if quality[i] < policy.quality_min:
            out.append((k, "low_tracking", float(s[i])))
        elif pred[i] == k or s[i] < policy.tau_low:
            out.append((k, "unknown", float(s[i])))
        elif s[i] < policy.tau_high:
            out.append((int(pred[i]), "retry", float(s[i])))
        else:
            out.append((int(pred[i]), "show", float(s[i])))
    return out


def compare_scorers(val_logits, val_y, k, T, emb=None, protos=None) -> dict:
    """Unknown-vs-known separation on validation, per scorer (AUROC, positives = known)."""
    y = np.asarray(val_y)
    out = {}
    for name in SCORERS:
        if name == "prototype" and (emb is None or protos is None):
            continue
        s = scores(name, val_logits, T, emb, protos)
        out[name] = auroc(s[y != k], s[y == k])
    return out
