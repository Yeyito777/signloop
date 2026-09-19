"""Local, inspectable nearest-reference DTW baseline; not an ASL-trained model.

Only explicit developer corpora are loaded. Runtime requests are never saved.
Distances and exp(-distance) similarities are NOT calibrated probabilities.
"""
from __future__ import annotations

import hashlib
import copy
import json
import math
from pathlib import Path
import statistics

from .service import ServiceError, validate_frames


def features(frames: list[dict], count: int = 24, diagnostics: dict | None = None) -> list:
    """Keep handshape, orientation, relative two-hand position and wrist motion.

    Translation/scale invariant, but deliberately NOT rotation/reflection
    invariant: orientation and handedness can distinguish signs. Inputs must
    carry imageAspectRatio and mirrored metadata. Legacy inputs assume square,
    mirrored images. No body-relative location.
    """
    validate_frames(frames)
    def reject(reason):
        if diagnostics is not None:
            diagnostics["observation_reason"] = reason
        return []
    if diagnostics is not None:
        diagnostics["frame_count"] = len(frames)
    if not frames or not frames[-1]["hands"]:
        return reject("no_hands")
    if len(frames) < 6:
        return reject("insufficient_frames")
    tracks = []
    for frame in frames:
        aspect = frame.get("imageAspectRatio", 1.)
        mirrored = frame.get("mirrored", True)
        hands = {}
        for hand in frame["hands"]:
            side = hand["handedness"]
            if not mirrored:
                side = {"Left": "Right", "Right": "Left"}.get(side, side)
            if side not in ("Left", "Right") or side in hands:
                # Conservative v1 gate. A single uncertain handedness frame
                # can reject a clip; report it rather than hide it as "Unknown".
                return reject("ambiguous_hand_identity")
            # MediaPipe z uses roughly image-width units, like x.
            xyz = [((j["x"] if mirrored else 1-j["x"])*aspect, j["y"], j["z"]*aspect)
                   for j in hand["joints"]]
            scale = math.dist(xyz[0][:2], xyz[9][:2])
            if scale < .015:
                continue
            hands[side] = (xyz, scale)
        tracks.append(hands)
    # Don't turn mostly missing/degenerate observations into a perfect match.
    if sum(bool(t) for t in tracks) < .7 * len(tracks) or not tracks[-1]:
        return reject("degenerate_or_missing_tracking")
    scales = [s for t in tracks for _, s in t.values()]
    scale = statistics.median(scales)
    # A common origin preserves relative placement of the two hands.
    first = next(t for t in tracks if t)
    origin = next(iter(sorted(first.items())))[1][0][0]
    start, end = frames[0]["timestampMS"], frames[-1]["timestampMS"]
    indices = sorted({min(range(len(frames)), key=lambda i:
                         abs(frames[i]["timestampMS"] - (start + (end-start)*k/(count-1))))
                      for k in range(count)})
    result = []
    for i in indices:
        step = []
        for side in ("Left", "Right"):
            if side not in tracks[i]:
                step.append(None)
                continue
            xyz, palm = tracks[i][side]
            # Wrist z is hand-relative in MediaPipe, not scene depth.
            motion = tuple((xyz[0][a] - origin[a]) / scale for a in (0, 1))
            shape = tuple((point[a] - xyz[0][a]) / palm for point in xyz for a in range(3))
            step.append((shape, motion))
        result.append(step)
    if diagnostics is not None:
        diagnostics["observation_reason"] = "usable"
    return result


def frame_distance(a, b) -> float:
    total = 0.
    active = 0
    for x, y in zip(a, b):
        if x is None and y is None:
            continue
        active += 1
        if x is None or y is None:
            total += 2.
        else:
            shape = math.sqrt(sum((u-v)**2 for u, v in zip(x[0], y[0])) / 63)
            motion = math.dist(x[1], y[1])
            total += .75 * shape + .25 * motion
    # Matching missing frames is not evidence of a sign.
    return total / active if active else 1.


def dtw(a: list, b: list) -> float:
    """Banded temporal alignment with normalized path cost; <=24 frames each."""
    if not a or not b:
        return math.inf
    n, m = len(a), len(b)
    band = max(abs(n-m), math.ceil(max(n, m) * .25))
    previous = [(math.inf, 0)] * (m+1)
    previous[0] = (0., 0)
    for i in range(1, n+1):
        current = [(math.inf, 0)] * (m+1)
        for j in range(max(1, i-band), min(m, i+band)+1):
            cost, steps = min(previous[j], current[j-1], previous[j-1], key=lambda v: v[0])
            current[j] = (cost + frame_distance(a[i-1], b[j-1]), steps+1)
        previous = current
    cost, steps = previous[m]
    return cost / steps if steps else math.inf


def load_corpus(path: Path) -> dict:
    if path.stat().st_size > 100_000_000:
        raise ValueError("Corpus exceeds 100 MB.")
    data = json.loads(path.read_text())
    if data.get("version") != 1 or not isinstance(data.get("samples"), list):
        raise ValueError("Expected version-1 corpus with samples.")
    seen, content, signers = set(), set(), {}
    for sample in data["samples"]:
        for key in ("id", "label", "signer", "source", "split"):
            if not isinstance(sample.get(key), str) or not sample[key].strip():
                raise ValueError(f"Sample needs nonempty {key}.")
        if sample["split"] not in ("train", "calibration", "test"):
            raise ValueError("Invalid split.")
        if sample["id"] in seen:
            raise ValueError("Duplicate recording ID.")
        seen.add(sample["id"])
        validate_frames(sample["frames"])
        # Detect copied geometry even if someone renamed the recording.
        canonical = [{"hands": f["hands"], "t": f["timestampMS"] - sample["frames"][0]["timestampMS"]}
                     for f in sample["frames"]]
        digest = hashlib.sha256(json.dumps(canonical, sort_keys=True).encode()).hexdigest()
        has_hands = any(f["hands"] for f in sample["frames"])
        if has_hands and digest in content:
            raise ValueError("Duplicate recording geometry; potential evaluation leakage.")
        if has_hands:
            content.add(digest)
        splits = signers.setdefault(sample["signer"], set())
        splits.add(sample["split"])
        if len(splits) > 1:
            raise ValueError("Signer occurs in more than one split.")
    return data


class ReferenceMatcher:
    model_name = "reference-dtw-v1"
    feature_function = staticmethod(features)

    def __init__(self, samples: list[dict], max_distance: float, min_margin: float):
        if not math.isfinite(max_distance) or not 0 <= max_distance <= 10:
            raise ValueError("Invalid maximum distance.")
        if not math.isfinite(min_margin) or not 0 <= min_margin <= 1:
            raise ValueError("Invalid relative margin.")
        self.max_distance, self.min_margin = max_distance, min_margin
        self.references = []
        for sample in samples:
            if sample["split"] == "train" and sample["label"] != "UNKNOWN":
                vector = self.feature_function(sample["frames"])
                if not vector:
                    raise ValueError(f"Unusable reference: {sample['id']}")
                self.references.append((sample["label"], sample["id"], vector))
        self.labels = sorted({r[0] for r in self.references})
        if len(self.labels) < 2:
            raise ValueError("Need at least two supported labels for ambiguity rejection.")

    def rank(self, frames: list[dict], diagnostics: dict | None = None) -> list[dict]:
        query = self.feature_function(frames, diagnostics=diagnostics)
        if not query:
            return []
        closest = {}
        for label, identifier, vector in self.references:
            distance = dtw(query, vector)
            if label not in closest or distance < closest[label]["distance"]:
                closest[label] = {"label": label, "distance": distance, "reference_id": identifier,
                                  "score": math.exp(-distance)}
        return sorted(closest.values(), key=lambda row: row["distance"])

    def decide(self, ranked: list[dict]) -> dict:
        reason = "insufficient_observation"
        accepted = False
        margin = 0.
        if ranked:
            best, second = ranked[:2]
            margin = (second["distance"] - best["distance"]) / max(second["distance"], 1e-9)
            reason = "too_distant" if best["distance"] > self.max_distance else "ambiguous"
            accepted = best["distance"] <= self.max_distance and margin >= self.min_margin
            if accepted:
                reason = "reference_match"
        return {"candidates": ranked, "unknown": not accepted, "reason": reason,
                "model": self.model_name, "mode": "reference_dtw", "experimental": True,
                "diagnostics": {"margin": margin, "max_distance": self.max_distance,
                                "min_margin": self.min_margin, "score_kind": "exp_negative_distance"}}

    def classify(self, frames: list[dict]) -> dict:
        diagnostics = {}
        ranked = self.rank(frames, diagnostics)
        result = self.decide(ranked)
        result["diagnostics"].update(diagnostics)
        if not ranked:
            result["reason"] = diagnostics["observation_reason"]
        return result


class TrackedReferenceMatcher(ReferenceMatcher):
    model_name = "reference-dtw-v2"

    @staticmethod
    def feature_function(frames, diagnostics=None):
        from .hand_tracking import stabilize
        details = diagnostics if diagnostics is not None else {}
        result = features(stabilize(frames, details), diagnostics=details)
        if (not result and frames and frames[-1]["hands"]
                and details.get("observation_reason") == "no_hands"):
            details["observation_reason"] = "unresolved_hand_tracking"
        return result


def reflect_hands(frames):
    """Global handedness reflection, NOT arbitrary finger/palm rotation."""
    result = copy.deepcopy(frames)
    for frame in result:
        for hand in frame["hands"]:
            hand["handedness"] = {"Left": "Right", "Right": "Left"}.get(
                hand["handedness"], hand["handedness"])
            for joint in hand["joints"]:
                joint["x"] = 1-joint["x"]
    return result


class MirroredReferenceMatcher(TrackedReferenceMatcher):
    """Dominant-hand augmentation for a narrow non-directional vocabulary.

    Not suitable for arbitrary labels: reflection can alter spatial meaning.
    This is an experimental augmentation, not another independent recording.
    """
    model_name = "reference-dtw-v3-mirror"
    reflection_labels = frozenset({"HELLO", "YES", "NO", "PLEASE", "THANK_YOU"})

    def __init__(self, samples, max_distance, min_margin):
        training = [s for s in samples if s["split"] == "train" and s["label"] != "UNKNOWN"]
        if not {s["label"] for s in training} <= self.reflection_labels:
            raise ValueError("Mirror augmentation is restricted to the five non-directional labels.")
        super().__init__(samples, max_distance, min_margin)
        # Original references retain priority on exact distance ties.
        for sample in training:
            vector = self.feature_function(reflect_hands(sample["frames"]))
            if vector:
                self.references.append((sample["label"], sample["id"] + ":reflected", vector))


MATCHERS = {cls.model_name: cls for cls in
            (ReferenceMatcher, TrackedReferenceMatcher, MirroredReferenceMatcher)}


class ReferenceService:
    """Same app-facing HTTP contract, with NO provider calls or API key."""
    caption_model = None
    mode = "reference_dtw"

    def __init__(self, matcher: ReferenceMatcher):
        self.matcher = matcher
        self.vocabulary = matcher.labels

    def classify(self, frames):
        return self.matcher.classify(frames)

    def caption(self, labels):
        raise ServiceError("disabled", "Captions are disabled for local recognition evaluation.", 503)
