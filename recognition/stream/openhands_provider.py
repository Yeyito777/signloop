"""OpenHands WLASL2000 pretrained recognizers (BiLSTM, BERT, ST-GCN, SL-GCN) behind RecognitionProvider.

Weights and configs come unmodified from
https://github.com/AI4Bharat/OpenHands/releases/tag/checkpoints_v1 ; model classes and pose transforms
are imported from the (unmodified) OpenHands source. Preprocessing = each checkpoint's own
`valid_pipeline` (PoseSelect 27 -> [PoseUniformSubsampling] -> CenterAndScaleNormalize by shoulders).
"""
from __future__ import annotations

import importlib.util
from pathlib import Path
import sys

import numpy as np
import torch
from omegaconf import OmegaConf

from .provider import RecognitionProvider, Window

ROOT = Path(__file__).resolve().parents[2] / ".runtime" / "oh"
ARCHS = {"lstm": ("wlasl_lstm/wlasl/lstm", "lstm.yaml"), "bert": ("wlasl_bert/wlasl/bert", "config.yaml"),
         "stgcn": ("wlasl_stgcn/wlasl/st_gcn", "config.yaml"), "slgcn": ("wlasl_slgcn/wlasl/sl_gcn", "config.yaml")}


def _load_pose_transforms():
    spec = importlib.util.spec_from_file_location("oh_pose_transforms", ROOT / "repo/openhands/datasets/pose_transforms.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class OpenHandsProvider(RecognitionProvider):
    def __init__(self, arch: str, glosses: list[str], device: str = "cpu"):
        if str(ROOT / "repo") not in sys.path:
            sys.path.insert(0, str(ROOT / "repo"))
        import types
        for name in ("pytorchvideo", "pytorchvideo.models", "pytorchvideo.models.hub"):   # video encoders, unused for pose models
            sys.modules.setdefault(name, types.ModuleType(name))
        import transformers
        if not hasattr(transformers, "BertLayer"):     # OpenHands predates transformers 4.5x moving it
            from transformers.models.bert.modeling_bert import BertLayer
            transformers.BertLayer = BertLayer
        from openhands.models.loader import get_model
        folder, cfg_name = ARCHS[arch]
        self.arch, self.name, self.labels, self.device = arch, f"openhands-wlasl2000-{arch}", glosses, torch.device(device)
        d = ROOT / folder
        self.cfg = OmegaConf.load(d / cfg_name)
        self.ckpt_path = next(d.glob("*.ckpt"))
        tf = _load_pose_transforms()
        self.transforms = []
        for step in self.cfg.data.valid_pipeline.transforms:
            (name, params), = OmegaConf.to_container(step).items()
            self.transforms.append(getattr(tf, name)(**(params or {})))
        self.model = get_model(self.cfg.model, 2, len(glosses))
        state = torch.load(self.ckpt_path, map_location="cpu", weights_only=False)["state_dict"]
        state = {k[len("model."):]: v for k, v in state.items() if k.startswith("model.")}
        missing = self.model.load_state_dict(state, strict=True)
        self.model.to(self.device).eval()
        self.params = sum(p.numel() for p in self.model.parameters())

    def _prep(self, w: Window) -> torch.Tensor:
        kps = torch.tensor(w.keypoints[:, :, :2], dtype=torch.float32).permute(2, 0, 1)   # (C,T,V)
        data = {"frames": kps}
        for t in self.transforms:
            data = t(data)
        return data["frames"]

    @torch.no_grad()
    def logits(self, windows) -> np.ndarray:
        """(N, 2000) raw logits. Equal-length inputs are batched; variable lengths run in groups."""
        xs = [self._prep(w) for w in windows]
        by_len: dict[int, list[int]] = {}
        for i, x in enumerate(xs):
            by_len.setdefault(x.shape[1], []).append(i)
        out = [None] * len(xs)
        for _, idxs in by_len.items():
            for a in range(0, len(idxs), 64):
                chunk = idxs[a:a + 64]
                y = self.model(torch.stack([xs[i] for i in chunk]).to(self.device)).float().cpu()
                for j, i in enumerate(chunk):
                    out[i] = y[j]
        return torch.stack(out).numpy()

    def probs(self, windows, vocab=None):
        z = torch.as_tensor(self.logits(windows))
        if vocab is not None:
            z = z[:, torch.as_tensor(vocab)]
        return torch.softmax(z, -1).numpy()

    def info(self):
        return {"provider": self.name, "architecture": {"lstm": "BiLSTM (pose-flattener + rnn)", "bert": "Transformer (BERT-style, 3 layers, hidden 96)",
                "stgcn": "ST-GCN (27-node pose graph)", "slgcn": "SL-GCN (decoupled GCN)"}[self.arch],
                "params": self.params, "checkpoint_mb": round(self.ckpt_path.stat().st_size / 1e6, 1),
                "input": "27 MediaPipe-Holistic keypoints (nose, eyes, shoulders, elbows, both hands), xy, shoulder-normalized",
                "classes": len(self.labels), "framework": "PyTorch (Lightning ckpt)"}
