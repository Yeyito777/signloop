"""Reference on-device engine: frame in, Prediction out. The Swift SignEngine mirrors this.

    camera frames -> Segmenter -> (segment) -> featurize -> model -> calibrated policy -> Prediction

The mobile layer receives only Prediction values (never landmark streams).
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Callable, Protocol

import numpy as np

from .features import FeatureConfig, Features, FeatureError, featurize_frames
from .metrics import softmax
from .openset import Policy, decide
from .segmenter import Segmenter, SegmenterConfig, State

UNKNOWN = "UNKNOWN"


@dataclass
class Prediction:
    label: str | None        # supported label, "UNKNOWN", or None when no attempt finished on this frame
    confidence: float        # temperature-scaled probability of the top known class (0 if none)
    state: str               # segmenter state after this frame
    tracking_quality: float  # 0..1 for the last attempted segment (live estimate while signing)
    tier: str | None = None  # show | retry | unknown | low_tracking | unusable
    reason: str | None = None
    segment: tuple[int, int] | None = None   # (start_ms, end_ms) of the attempt that produced this prediction


class Runner(Protocol):
    def __call__(self, features: Features) -> tuple[np.ndarray, np.ndarray]:
        """-> (logits (K+1,), embedding (E,))"""


class SignEngine:
    def __init__(self, runner: Runner, policy: Policy, feature_cfg: FeatureConfig = FeatureConfig(),
                 seg_cfg: SegmenterConfig = SegmenterConfig(), protos=None):
        self.runner, self.policy, self.fcfg, self.protos = runner, policy, feature_cfg, protos
        self.segmenter = Segmenter(seg_cfg)
        self.quality = 0.0

    def reset(self):
        self.segmenter.reset()
        self.quality = 0.0

    def classify_segment(self, frames: list[dict]) -> Prediction:
        try:
            feats = featurize_frames(frames, self.fcfg)
        except FeatureError as e:
            return Prediction(UNKNOWN, 0.0, State.PREDICTION.value, 0.0, "unusable", str(e))
        logits, emb = self.runner(feats)
        (idx, tier, score), = decide(self.policy, logits[None], [feats.tracking_quality],
                                     None if emb is None else emb[None], self.protos)
        k = len(self.policy.known)
        probs = softmax(logits[None], self.policy.temperature)[0]
        conf = float(probs[:k].max())
        label = self.policy.known[idx] if (idx < k and tier == "show") else UNKNOWN
        return Prediction(label, conf, State.PREDICTION.value, feats.tracking_quality, tier)

    def update(self, frame: dict) -> Prediction:
        seg = self.segmenter.update(frame)
        if seg is None:
            return Prediction(None, 0.0, self.segmenter.state.value, self.quality)
        pred = self.classify_segment(seg.frames)
        self.quality = pred.tracking_quality
        self.segmenter.finish(int(frame["timestampMS"]))
        pred.reason = pred.reason or seg.reason
        pred.segment = (seg.start_ms, seg.end_ms)
        return pred


def torch_runner(model, device="cpu") -> Runner:
    import torch
    from .models import to_tensors
    model.eval()

    def run(f: Features):
        batch = {"nodes": f.nodes[None], "glob": f.glob[None], "motion": f.motion[None], "mask": f.mask[None],
                 "meta": f.meta[None]}
        with torch.no_grad():
            out = model(to_tensors(batch, device))
        return out["logits"][0].float().cpu().numpy(), out["emb"][0].float().cpu().numpy()

    return run
