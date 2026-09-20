"""Read/validate the compact temporal corpus locally; no network or app service."""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
import re

from .basic_signs import FACE_IDS, LABELS


def validate_arrays(a):
    import numpy as np
    t = a["timestamp_ms"]
    if t.ndim != 1 or not 1 <= len(t) <= 2000 or t[0] != 0 or not (np.diff(t) > 0).all():
        raise ValueError("Invalid temporal timestamps.")
    n = len(t)
    shapes = {"hands": (n, 2, 21, 3), "hand_valid": (n, 2), "hand_sides": (n, 2),
              "pose": (n, 25, 3), "pose_valid": (n, 25), "pose_confidence": (n, 25, 2),
              "face_anchors": (n, len(FACE_IDS), 3), "face_valid": (n,)}
    for name, expected in shapes.items():
        if a[name].shape != expected or not np.isfinite(a[name]).all():
            raise ValueError(f"Invalid {name} shape/values.")
    for name in ("hand_valid", "pose_valid", "face_valid"):
        if a[name].dtype.kind != "b":
            raise ValueError("Explicit boolean missing-data masks required.")
    if not np.array_equal(a["face_ids"], FACE_IDS):
        raise ValueError("Wrong facial-anchor schema.")
    for name in ("width", "height", "source_fps"):
        if a[name].shape != () or not np.isfinite(a[name]) or float(a[name]) <= 0:
            raise ValueError("Invalid source geometry.")
    names = list(a["blendshape_names"])
    if len(names) not in (0, 52) or len(set(names)) != len(names):
        raise ValueError("Invalid blendshape names.")
    if a["face_valid"].any() and len(names) != 52:
        raise ValueError("Face requires the expression-channel schema.")
    if a["blendshapes"].shape != (n, len(names)) or not np.isfinite(a["blendshapes"]).all():
        raise ValueError("Invalid expression matrix.")
    if not ((a["blendshapes"] >= 0) & (a["blendshapes"] <= 1)).all():
        raise ValueError("Invalid expression coefficient.")
    if not np.isin(a["hand_sides"], (-1, 0, 1)).all():
        raise ValueError("Invalid wrist assignment.")
    if np.any(a["hand_sides"][~a["hand_valid"]] != -1):
        raise ValueError("Missing hand assigned to a wrist.")
    if np.any((a["hand_sides"][:, 0] >= 0) & (a["hand_sides"][:, 0] == a["hand_sides"][:, 1])):
        raise ValueError("Both hands assigned to the same wrist.")


def samples(folder, split=None):
    """Yield (label/split/provenance record, time-series arrays), never pickle."""
    import numpy as np
    folder = Path(folder)
    plan_path = folder/"plan.json"
    plan = json.loads(plan_path.read_text())
    report = json.loads((folder/"report.json").read_text())
    binding = hashlib.sha256(plan_path.read_bytes()).hexdigest()
    if not report["complete"] or report["plan_sha256"] != binding:
        raise ValueError("Corpus not complete or report does not match plan.")
    if len(report["rows"]) != len(plan["samples"]) or len({s["id"] for s in plan["samples"]}) != len(plan["samples"]):
        raise ValueError("Incomplete or duplicate corpus members.")
    if [(r["id"], r["label"], r["split"], r["signer"]) for r in report["rows"]] != [
        (r["id"], r["label"], r["split"], r["signer"]) for r in plan["samples"]]:
        raise ValueError("Report selection differs from the frozen plan.")
    signers = defaultdict(set)
    for row in plan["samples"]:
        signers[row["split"]].add(row["signer"])
    if any(signers[a] & signers[b] for a, b in (("train", "val"), ("train", "test"), ("val", "test"))):
        raise ValueError("Signer leakage.")
    for row in plan["samples"]:
        if not re.fullmatch("[0-9a-f]{64}", row["id"]):
            raise ValueError("Invalid corpus identifier.")
        if split is not None and row["split"] != split:
            continue
        with np.load(folder/"coordinates"/(row["id"]+".npz"), allow_pickle=False) as stored:
            arrays = {k: stored[k] for k in stored.files}
        if str(arrays["plan_sha256"]) != binding:
            raise ValueError("Coordinate cache does not match plan.")
        validate_arrays(arrays)
        yield row, arrays


def summary(folder):
    import numpy as np
    counts, per_label, signers = Counter(), defaultdict(Counter), defaultdict(set)
    for row, a in samples(folder):
        n = len(a["timestamp_ms"])
        counts["clips"] += 1
        counts["frames"] += n
        counts["hand_frames"] += int(a["hand_valid"].any(axis=1).sum())
        counts["associated_hand_frames"] += int((a["hand_sides"] >= 0).any(axis=1).sum())
        counts["shoulder_frames"] += int(a["pose_valid"][:, [11, 12]].all(axis=1).sum())
        counts["face_frames"] += int(a["face_valid"].sum())
        counts["video_duration_ms"] += int(a["timestamp_ms"][-1])
        signers[row["split"]].add(row["signer"])
        p = per_label[row["label"]]
        p[row["split"]+"_clips"] += 1
        # Availability diagnostics, not a label-correctness or accuracy measure.
        p[row["split"]+"_with_6_hand_frames"] += int(a["hand_valid"].any(axis=1).sum() >= 6)
        p[row["split"]+"_with_6_body_hand_frames"] += int(
            np.sum(a["hand_valid"].any(axis=1) & a["pose_valid"][:, [11, 12]].all(axis=1)) >= 6)
    return {"validated": True, "labels": json.loads((Path(folder)/"plan.json").read_text())["labels"], "counts": dict(counts),
            "signers": {k: len(v) for k, v in signers.items()},
            "coordinate_bytes": sum(p.stat().st_size for p in (Path(folder)/"coordinates").glob("*.npz")),
            "per_label": dict(per_label),
            "scope": "Observation availability only; not sign-recognition accuracy."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folder", type=Path)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    result = summary(args.folder)
    if args.out:
        if ".runtime" not in args.out.resolve().parts:
            parser.error("Keep detailed research reports in ignored .runtime.")
        args.out.write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
