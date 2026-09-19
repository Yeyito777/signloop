"""Offline Microsoft ASL Citizen checkpoint benchmark; no phone/provider uploads.

Preprocessing adapters derived from Microsoft ASL-citizen-code (MIT);
see third_party/ASL-Citizen-LICENSE.txt for the preserved notice.

Run only on licensed local research assets in ignored .runtime directories.
Pinned upstream architecture is imported, but its training/testing scripts are
never executed. Checkpoints are hash-verified and loaded with weights_only=True.
"""
import argparse
from collections import Counter
import csv
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import statistics
import subprocess
import sys
import time

from .research_data import LICENSE

UPSTREAM = "17f0148b00ef87a5957ec103da8d10bd8eb1fa23"
WEIGHTS = {
    "stgcn": "b08d84afb5a0fdf4c723fd7be2db897b2490a921ccf538cff1b345f905934d68",
    "I3D": "3538319620331d5ba731e0f9ac79161deeb37a895b7680d215864fc00a14477d"}
METADATA = {
    "train": "87a105649b98ea577182ebfce49d59fe9ca834a2489384f6fe7bc03f14966329",
    "val": "6ac78c9d551dfcc81d225a5279d7637c2891a4490851234be6e4674666e21366",
    "test": "b1dee8f81204895ca1760f6bd582eec84cf390b9c97c4387e49b9cc6b906b21e"}
SUPPORTED = {"HELLO", "YES", "NO", "PLEASE", "THANKYOU", "ILOVEYOU"}
KEYPOINTS = [0, 2, 5, 11, 12, 13, 14, 33, 37, 38, 41, 42, 45, 46, 49,
             50, 53, 54, 58, 59, 62, 63, 66, 67, 70, 71, 74]
EDGES = [[2, 0], [1, 0], [0, 3], [0, 4], [3, 5], [4, 6], [5, 7],
         [6, 17], [7, 8], [7, 9], [9, 10], [7, 11], [11, 12], [7, 13],
         [13, 14], [7, 15], [15, 16], [17, 18], [17, 19], [19, 20],
         [17, 21], [21, 22], [17, 23], [23, 24], [17, 25], [25, 26]]


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def plan(metadata, caches):
    """Freeze all cached official val/test clips BEFORE checkpoint inference.

    Do not reuse the project's V2 `test`: those were official training people.
    """
    rows = {}
    for split, digest in METADATA.items():
        path = metadata/(split+".csv")
        if sha(path) != digest:
            raise ValueError("Unexpected official metadata.")
        with path.open() as stream:
            rows[split] = list(csv.DictReader(stream))
    signers = {s: {r["Participant ID"] for r in data} for s, data in rows.items()}
    if any(signers[a] & signers[b] for a, b in (("train", "val"), ("train", "test"), ("val", "test"))):
        raise ValueError("Official splits must be participant disjoint.")
    vocabulary = sorted({r["Gloss"].strip() for r in rows["train"]})
    if len(vocabulary) != 2731:
        raise ValueError("Checkpoint expects 2731 sorted training labels.")
    files = {p.stem: p.resolve() for root in caches for p in root.glob("*.mp4")}
    samples = []
    for split in ("val", "test"):
        for row in rows[split]:
            identifier = hashlib.sha256(row["Video file"].encode()).hexdigest()
            if identifier in files:
                video = files[identifier]
                samples.append({"id": identifier, "split": split, "gloss": row["Gloss"],
                                "signer": row["Participant ID"], "video": str(video),
                                "video_sha256": sha(video)})
    if not all(any(s["split"] == split for s in samples) for split in ("val", "test")):
        raise ValueError("Both official validation and test caches required.")
    return {"protocol": "citizen-baselines-v1", "upstream": UPSTREAM, "weights": WEIGHTS,
            "metadata": METADATA, "vocabulary": vocabulary,
            "samples": sorted(samples, key=lambda s: (s["split"] != "val", s["id"])),
            "scope": "Previously inspected local clips; official train excluded. "
                     "Not a new live-signer or natural-nonsigning benchmark."}


def downsample(data, maximum=128):
    import numpy as np
    increment = min(1., maximum/len(data))
    cumulative, count, selected = 0., 0, []
    for frame in data:
        cumulative += increment
        if cumulative > count:
            count += 1
            selected.append(frame)
    return np.asarray(selected[:maximum])


def pose_tensor(data):
    """Match upstream padding, shoulder normalization, hand reorder and graph.

    Input ordering is POSE, RIGHT HAND, LEFT HAND (unmirrored Holistic).
    In particular, padded zeros participate in upstream normalization.
    """
    import numpy as np
    if data.ndim != 3 or data.shape[1:] != (75, 2) or not 1 <= len(data) <= 2000:
        raise ValueError("Expected 1..2000 frames of 75 XY landmarks.")
    if not np.isfinite(data).all():
        raise ValueError("Nonfinite pose.")
    data = np.asarray(data, dtype=np.float64).copy()
    if len(data) > 128:
        data = downsample(data)
    elif len(data) < 128:
        data = np.pad(data, ((0, 128-len(data)), (0, 0), (0, 0)))
    left, right = data[:, 11], data[:, 12]
    center = ((left+right)/2).sum(axis=0)/128
    distance = np.mean(np.sqrt(((left-right)**2).sum(-1)))
    if distance != 0:
        data = (data-center)/distance
    data = np.concatenate((data[:, :33], data[:, 54:75], data[:, 33:54]), axis=1)
    return data[:, KEYPOINTS].transpose(2, 0, 1).copy()


def extract_pose(video):
    import cv2
    import mediapipe as mp
    import numpy as np
    if mp.__version__ != "0.10.21":
        raise ValueError("Pinned MediaPipe 0.10.21 required.")
    cap = cv2.VideoCapture(str(video))
    total, fps = int(cap.get(cv2.CAP_PROP_FRAME_COUNT)), cap.get(cv2.CAP_PROP_FPS)
    if not cap.isOpened() or not 1 <= total <= 2000 or not 0 < fps <= 120:
        cap.release()
        raise ValueError("Invalid/truncated/oversized video.")
    data = np.zeros((total, 75, 2), dtype=np.float64)
    timings = []
    try:
        with mp.solutions.holistic.Holistic(static_image_mode=False,
                                          min_detection_confidence=.5) as detector:
            for i in range(total):
                ok, image = cap.read()
                if not ok:
                    raise ValueError("Truncated source; cannot drop clip.")
                start = time.perf_counter()
                result = detector.process(cv2.cvtColor(image, cv2.COLOR_BGR2RGB))
                timings.append((time.perf_counter()-start)*1000)
                for offset, landmarks in ((0, result.pose_landmarks),
                                          (33, result.right_hand_landmarks),
                                          (54, result.left_hand_landmarks)):
                    if landmarks:
                        for j, p in enumerate(landmarks.landmark):
                            data[i, offset+j] = p.x, p.y
    finally:
        cap.release()
    return data, fps, timings


def rgb_tensor(video):
    """Reproduce official 'RGB' loader (actually OpenCV BGR, deliberately).

    Centered frame skipping, resize, seeded upstream padding and center crop.
    A full isolated clip is not a causal live stream.
    """
    import cv2
    import numpy as np
    cap = cv2.VideoCapture(str(video))
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    if not cap.isOpened() or not 1 <= total <= 2000:
        cap.release()
        raise ValueError("Invalid video.")
    skip = 3 if total >= 160 else 2 if total >= 96 else 1
    start = int(np.clip((total-64*skip)//2, 0, {1: 64, 2: 96, 3: 160}[skip]))
    images = []
    try:
        cap.set(cv2.CAP_PROP_POS_FRAMES, start)
        for offset in range(min(64*skip, total-start)):
            ok, image = cap.read()
            if not ok:
                raise ValueError("Truncated source.")
            if offset % skip:
                continue
            # Preserve upstream's dimension/order quirks; changing BGR to RGB
            # or aspect ratio here would invalidate this reproduction.
            w, h, _ = image.shape
            if min(w, h) < 226:
                scale = 226/min(w, h)
                image = cv2.resize(image, (0, 0), fx=scale, fy=scale)
            if w > 256 or h > 256:
                image = cv2.resize(image, (math.ceil(w*(256/w)), math.ceil(h*(256/h))))
            images.append((image/255.)*2-1)
    finally:
        cap.release()
    images = np.asarray(images, dtype=np.float32)
    if len(images) < 64:
        # Same RNG as upstream; caller seeds once before a deterministic order.
        pad = images[0] if np.random.random_sample() > .5 else images[-1]
        images = np.concatenate((images, np.tile(pad[None], (64-len(images), 1, 1, 1))))
    _, height, width, _ = images.shape
    top, left = int(np.round((height-224)/2)), int(np.round((width-224)/2))
    return images[:, top:top+224, left:left+224].transpose(3, 0, 1, 2).copy()


def load_model(kind, upstream, checkpoint):
    import torch
    if sha(checkpoint) != WEIGHTS[kind]:
        raise ValueError("Unrecognized checkpoint.")
    revision = subprocess.check_output(["git", "-C", str(upstream), "rev-parse", "HEAD"],
                                      text=True).strip()
    if revision != UPSTREAM:
        raise ValueError("Unrecognized upstream source revision.")
    subprocess.run(["git", "-C", str(upstream), "diff", "--exit-code", "HEAD"], check=True,
                   stdout=subprocess.DEVNULL)
    if kind == "stgcn":
        sys.path.insert(0, str((upstream/"ST-GCN").resolve()))
        from architecture.st_gcn import STGCN
        from architecture.fc import FC
        from architecture.network import Network
        model = Network(STGCN(2, {"num_nodes": 27, "center": 0, "inward_edges": EDGES}, True),
                        FC(256, 2731, dropout_ratio=.05)).double()
    else:
        spec = importlib.util.spec_from_file_location("citizen_i3d", upstream/"I3D/pytorch_i3d.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        model = module.InceptionI3d(400, in_channels=3)
        model.replace_logits(2731)
    model.load_state_dict(torch.load(checkpoint, map_location="cpu", weights_only=True), strict=True)
    return model.eval()


def rank(logits, vocabulary):
    import numpy as np
    values = np.asarray(logits)
    if values.shape != (2731,) or not np.isfinite(values).all() or len(vocabulary) != 2731:
        raise ValueError("Unexpected output shape/values.")
    probabilities = np.exp(values-values.max())
    probabilities /= probabilities.sum()
    order = np.argsort(-values, kind="stable")[:5]
    return [{"label": vocabulary[i], "score": float(probabilities[i])} for i in order]


def accepted(ranked, score, margin):
    a, b = ranked[:2]
    return (a["label"] if a["label"] in SUPPORTED and a["score"] > score and
            a["score"]-b["score"] >= margin else None)


def summarize(rows, score, margin):
    counts, per_label = Counter(), {}
    for row in rows:
        truth = row["gloss"]
        chosen = accepted(row["ranked"], score, margin)
        supported = truth in SUPPORTED
        counts["clips"] += 1
        counts["supported" if supported else "unsupported"] += 1
        counts["all_gloss_raw_top1_correct"] += row["ranked"][0]["label"] == truth
        counts["supported_raw_top1_correct"] += supported and row["ranked"][0]["label"] == truth
        counts["correct_accepted"] += supported and chosen == truth
        counts["wrong_accepted"] += chosen is not None and chosen != truth
        counts["unsupported_false_accept"] += not supported and chosen is not None
        if supported:
            c = per_label.setdefault(truth, Counter())
            c["clips"] += 1
            c["raw_correct"] += row["ranked"][0]["label"] == truth
            c["accepted_correct"] += chosen == truth
            c["wrong"] += chosen is not None and chosen != truth
    return {"counts": counts, "per_label": per_label}


def calibrate(rows):
    best, chosen = None, None
    for score in (i*.025 for i in range(41)):
        for margin in (0, .025, .05, .1, .2, .3):
            counts = summarize(rows, score, margin)["counts"]
            if counts["wrong_accepted"]:
                continue
            objective = (counts["correct_accepted"], score, margin)
            if best is None or objective > best:
                best, chosen = objective, (score, margin)
    assert chosen is not None  # score>1 is reject-all.
    return chosen


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("plan", "pose", "infer"))
    parser.add_argument("--metadata", type=Path)
    parser.add_argument("--clips", type=Path, nargs="+")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--upstream", type=Path)
    parser.add_argument("--kind", choices=("stgcn", "I3D"))
    parser.add_argument("--checkpoint", type=Path)
    parser.add_argument("--device", choices=("cpu", "mps"), default="cpu")
    parser.add_argument("--accept-research-license", action="store_true")
    args = parser.parse_args()
    if not args.accept_research_license or ".runtime" not in args.out.parts:
        parser.error(f"Read {LICENSE}; require acknowledgment and ignored .runtime output.")
    args.out.mkdir(parents=True, exist_ok=True)
    plan_path = args.out/"plan.json"
    if args.mode == "plan":
        if not args.metadata or not args.clips:
            parser.error("Plan requires --metadata and --clips.")
        result = plan(args.metadata, args.clips)
        with plan_path.open("x") as stream:
            json.dump(result, stream, indent=2)
        print(Counter(s["split"] for s in result["samples"]))
        return
    manifest = json.loads(plan_path.read_text())
    if (manifest["upstream"] != UPSTREAM or manifest["weights"] != WEIGHTS or
            manifest["metadata"] != METADATA):
        raise ValueError("Incompatible frozen plan.")
    import numpy as np
    if args.mode == "infer":
        if not args.kind or not args.checkpoint or not args.upstream:
            parser.error("Inference requires --kind, --checkpoint and --upstream.")
        import torch
        torch.set_num_threads(4)
        np.random.seed(0)
        model = load_model(args.kind, args.upstream, args.checkpoint)
        if args.device == "mps" and args.kind != "I3D":
            raise ValueError("Preserve ST-GCN float64 on CPU.")
        model = model.to(args.device)
    (args.out/"poses").mkdir(exist_ok=True)
    rows, parameters = [], None
    for index, sample in enumerate(manifest["samples"]):
        if sha(sample["video"]) != sample["video_sha256"]:
            raise ValueError("Source clip changed.")
        cache = args.out/"poses"/(sample["id"]+".npz")
        if args.mode == "pose":
            if not cache.exists():
                data, fps, timings = extract_pose(sample["video"])
                np.savez_compressed(cache, data=data, fps=fps, timings=timings,
                                    video_sha256=sample["video_sha256"])
        else:
            # Freeze policy on official validation before FIRST test inference.
            if sample["split"] == "test" and parameters is None:
                parameters = calibrate(rows)
                print("FROZEN score/margin", parameters, flush=True)
                (args.out/(args.kind+"-calibration.json")).write_text(json.dumps(
                    {"parameters": parameters, "summary": summarize(rows, *parameters)}, indent=2))
            if args.kind == "stgcn":
                with np.load(cache, allow_pickle=False) as stored:
                    if str(stored["video_sha256"]) != sample["video_sha256"]:
                        raise ValueError("Pose cache does not match clip.")
                    value = pose_tensor(stored["data"])
            else:
                value = rgb_tensor(sample["video"])
            begin = time.perf_counter()
            with torch.inference_mode():
                output = model(torch.from_numpy(value)[None].to(args.device))
                if args.kind == "I3D":
                    output = torch.nn.functional.interpolate(output, 64, mode="linear",
                                                             align_corners=False).max(dim=2).values
                logits = output[0].cpu().numpy()  # also synchronizes MPS before timing
            elapsed = (time.perf_counter()-begin)*1000
            rows.append({k: sample[k] for k in ("id", "split", "signer", "gloss")} |
                        {"ranked": rank(logits, manifest["vocabulary"]), "model_ms": elapsed})
            # Save completed observations only, never report partial accuracy as complete.
            (args.out/(args.kind+"-progress.json")).write_text(json.dumps({"complete": False, "rows": rows}))
        print(f"{args.mode} {args.kind or ''} {index+1}/{len(manifest['samples'])}", flush=True)
    if args.mode == "infer":
        duration = [r["model_ms"] for r in rows]
        report = {"complete": True, "plan_sha256": sha(plan_path), "kind": args.kind,
                  "parameters": parameters, "scope": manifest["scope"],
                  "mode": "whole isolated clip; not streaming or phone timing",
                  "device": args.device,
                  "model_median_ms": statistics.median(duration),
                  "model_p95_ms": sorted(duration)[int(.95*(len(duration)-1))],
                  "splits": {split: summarize([r for r in rows if r["split"] == split], *parameters)
                             for split in ("val", "test")}, "rows": rows}
        (args.out/(args.kind+"-report.json")).write_text(json.dumps(report, indent=2))
        print(json.dumps({k: v for k, v in report.items() if k != "rows"}, indent=2))


if __name__ == "__main__":
    main()
