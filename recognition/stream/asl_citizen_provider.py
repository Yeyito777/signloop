"""Microsoft ASL Citizen ST-GCN as a RecognitionProvider. WRAPPER ONLY, NOT RUN HERE.

It reuses the pinned, hash-verified loader and preprocessing in backend/research_citizen.py and consumes the
same 75-point Holistic windows as the OpenHands providers (both use the identical 27-keypoint subset).
It cannot be run without licensed assets this machine does not have:
  * the 2,731-gloss ordering = sorted, stripped glosses of the ASL Citizen TRAIN metadata (dataset license
    click-through: noncommercial research only), passed as a text file with one gloss per line;
  * the pinned upstream checkout (microsoft/ASL-citizen-code @ 17f0148...) and ASL_citizen_stgcn_weights.zip
    extracted (sha256 checked by the loader).
If anything is missing it raises ProviderUnavailable. It never invents labels.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np

from .provider import RecognitionProvider, Window


class ProviderUnavailable(RuntimeError):
    pass


class ASLCitizenProvider(RecognitionProvider):
    name = "asl-citizen-stgcn"

    def __init__(self, upstream: str | Path, checkpoint: str | Path, glosses_file: str | Path):
        for p, what in ((upstream, "pinned upstream checkout"), (checkpoint, "ST-GCN checkpoint"), (glosses_file, "gloss list from licensed train metadata")):
            if not Path(p).exists():
                raise ProviderUnavailable(f"ASL Citizen provider needs the {what}: {p} not found")
        glosses = [g.strip() for g in Path(glosses_file).read_text().splitlines() if g.strip()]
        if len(glosses) != 2731:
            raise ProviderUnavailable(f"expected 2731 glosses, got {len(glosses)}")
        import torch
        from backend.research_citizen import load_model
        self.labels, self._torch = glosses, torch
        self.model = load_model("stgcn", Path(upstream), Path(checkpoint))
        self.params = sum(p.numel() for p in self.model.parameters())

    def logits(self, windows):
        from backend.research_citizen import pose_tensor
        torch = self._torch
        out = []
        with torch.no_grad():
            for w in windows:
                x = torch.tensor(pose_tensor(np.asarray(w.keypoints[:, :, :2], np.float64))[None])
                out.append(self.model(x.double())[0].float().numpy())
        return np.stack(out)

    def probs(self, windows, vocab=None):
        z = self.logits(windows)
        if vocab is not None:
            z = z[:, vocab]
        z = z - z.max(1, keepdims=True)
        e = np.exp(z)
        return e / e.sum(1, keepdims=True)

    def info(self):
        return {"provider": self.name, "architecture": "ST-GCN (27-node pose graph)", "classes": 2731,
                "checkpoint_mb": 28.9, "status": "wrapper written; not executed (licensed metadata required)"}
