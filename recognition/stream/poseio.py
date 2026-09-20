"""WLASL pose clips (OpenHands' pre-extracted MediaPipe Holistic poses), read straight from the zip."""
from __future__ import annotations

import json
from pathlib import Path
import pickle
import threading
import zipfile

import numpy as np

from .provider import Window

FPS = 25.0  # WLASL videos are ~25 fps; poses are per frame


class WLASLPoses:
    def __init__(self, pose_zip: str | Path, split_json: str | Path):
        self._zip = zipfile.ZipFile(pose_zip)
        self._lock = threading.Lock()
        self._names = {Path(n).stem: n for n in self._zip.namelist() if n.endswith(".pkl")}
        content = json.loads(Path(split_json).read_text())
        # identical to openhands WLASLDataset.read_glosses / read_original_dataset
        self.glosses = sorted(e["gloss"] for e in content)
        self.gloss_id = {g: i for i, g in enumerate(self.glosses)}
        self.items = []          # (video_id, class_id, split)
        for e in content:
            for inst in e["instances"]:
                if inst["video_id"] in self._names:
                    self.items.append((inst["video_id"], self.gloss_id[e["gloss"]], inst["split"]))

    def split(self, name: str):
        return [it for it in self.items if it[2] == name]

    def clip(self, video_id: str):
        with self._lock:
            d = pickle.loads(self._zip.read(self._names[video_id]))
        return np.asarray(d["keypoints"], np.float32), np.asarray(d["confidences"], np.float32)

    def window(self, video_id: str, t0: float | None = None, t1: float | None = None) -> Window:
        kp, cf = self.clip(video_id)
        n = len(kp)
        a = 0 if t0 is None else max(0, int(round(t0 * FPS)))
        b = n if t1 is None else min(n, max(a + 1, int(round(t1 * FPS))))
        return Window(a / FPS, b / FPS, kp[a:b], cf[a:b])


def official_subset(split_dir: str | Path, size: int) -> set[str]:
    """Glosses of WLASL's own asl{size} subset (the most frequent classes)."""
    content = json.loads((Path(split_dir) / f"asl{size}.json").read_text())
    return {e["gloss"] for e in content}


def nested_random_vocab(n_classes: int, sizes, seed: int = 0) -> dict[int, np.ndarray]:
    """Nested random class subsets (each larger set contains the smaller ones) so vocabulary-scaling
    curves compare like with like. Seeded and recorded in every report."""
    order = np.random.default_rng(seed).permutation(n_classes)
    return {int(s): np.sort(order[:s]) for s in sizes}
