"""Local calibration-only face-context ablation; never an app/network service.

Two separate environments: extract with pinned MediaPipe, evaluate with LiteRT.
Research coordinates stay in ignored .runtime. No threshold tuning or test clips.
"""
import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import statistics
import time

from .research_confirmation import calibration_samples, CORPUS_SHA
from .research_data import LICENSE
from .research_motion import pinch_motion
from .research_pretrained import PretrainedResearchMatcher, ranked_logits

FACE_SHA = "64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff"
FACE_URL = ("https://storage.googleapis.com/mediapipe-models/face_landmarker/"
            "face_landmarker/float16/1/face_landmarker.task")


def valid_face(points):
    # Reject malformed/ambiguous input, never invent a face center.
    return (isinstance(points, list) and len(points) == 468 and
            all(isinstance(p, list) and len(p) == 3 and
                all(isinstance(v, (int, float)) and not isinstance(v, bool)
                    and math.isfinite(v) for v in p) for p in points))


def face_at(observations, timestamp, max_age=200):
    """Causal hold only; a more recent missing/ambiguous face clears the hold."""
    prior = [f for f in observations if f["timestampMS"] <= timestamp]
    if not prior:
        return None
    latest = max(prior, key=lambda f: f["timestampMS"])
    if timestamp-latest["timestampMS"] > max_age or not valid_face(latest["face"]):
        return None
    return latest["face"]


def inject_face(tensor, frames, observations):
    """Copy instead of mutating the hands-only control tensor."""
    result = tensor.copy()
    for i, frame in enumerate(frames):
        face = face_at(observations, frame["timestampMS"])
        if face is not None:
            result[i, :468] = [
                (p[0] if frame.get("mirrored", True) else 1-p[0], p[1], p[2])
                for p in face]
    return result


def windows(frames):
    """Same fixed inputs for both ablations: causal 1.2s, nearest 15Hz, >=250ms.

    Diagnostic scheduling only, not a native UI/worker latency replay.
    """
    last = -math.inf
    for frame in frames:
        end = frame["timestampMS"]
        if end-last < 250 or not frame["hands"]:
            continue
        available = [f for f in frames if end-1200 <= f["timestampMS"] <= end]
        chosen = {}
        for step in range(19):
            target = end-step*1000/15
            if target < available[0]["timestampMS"]:
                break
            nearest = min(available, key=lambda f: (abs(f["timestampMS"]-target),
                                                   -f["timestampMS"]))
            chosen[nearest["timestampMS"]] = nearest
        window = [chosen[t] for t in sorted(chosen)]
        if len(window) >= 6:
            last = end
            yield window


def extract(video, model, frames, rate):
    import cv2
    import mediapipe as mp
    if mp.__version__ != "0.10.21":
        raise ValueError("Use MediaPipe 0.10.21.")
    cap = cv2.VideoCapture(str(video))
    fps, total = cap.get(cv2.CAP_PROP_FPS), int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    if not cap.isOpened() or fps <= 0 or total <= 0:
        cap.release()
        raise ValueError("Cannot decode source; no silent sample omissions.")
    start = max(0, (total-int(3*fps))//2)
    end = min(total, start+int(3*fps))
    timestamps = {f["timestampMS"] for f in frames}
    options = mp.tasks.vision.FaceLandmarkerOptions(
        base_options=mp.tasks.BaseOptions(model_asset_path=str(model)),
        running_mode=mp.tasks.vision.RunningMode.VIDEO, num_faces=2,
        min_face_detection_confidence=.5, min_face_presence_confidence=.5,
        min_tracking_confidence=.5)
    observations, elapsed, seen = [], [], set()
    deadline = 0.
    try:
        with mp.tasks.vision.FaceLandmarker.create_from_options(options) as detector:
            cap.set(cv2.CAP_PROP_POS_FRAMES, start)
            for index in range(start, end):
                ok, image = cap.read()
                if not ok:
                    raise ValueError("Truncated video.")
                stamp = round((index-start)/fps*1000)
                if stamp not in timestamps:
                    continue
                seen.add(stamp)
                # At full rate, use EVERY already-admitted hand frame. A
                # second gate on rounded milliseconds would quantize twice.
                if rate != 24 and stamp+1e-9 < deadline:
                    continue
                deadline = stamp+1000/rate if stamp-deadline > 1000/rate else deadline+1000/rate
                image = cv2.cvtColor(cv2.flip(image, 1), cv2.COLOR_BGR2RGB)
                begin = time.perf_counter()
                result = detector.detect_for_video(
                    mp.Image(image_format=mp.ImageFormat.SRGB, data=image), stamp)
                elapsed.append((time.perf_counter()-begin)*1000)
                # Two faces are not associated to hands: reject rather than guess.
                face = ([[p.x, p.y, p.z] for p in result.face_landmarks[0][:468]]
                        if len(result.face_landmarks) == 1 else None)
                observations.append({"timestampMS": stamp, "face": face})
    finally:
        cap.release()
    if seen != timestamps:
        raise ValueError("Cached hand timestamps do not align with source video.")
    return {"observations": observations, "inference_ms": elapsed}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("extract", "evaluate"))
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--hand-cache", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--clips", type=Path)
    parser.add_argument("--face-model", type=Path)
    parser.add_argument("--model", type=Path)
    parser.add_argument("--vocabulary", type=Path)
    parser.add_argument("--rate", type=int, choices=(6, 24), default=6)
    parser.add_argument("--accept-research-license", action="store_true")
    args = parser.parse_args()
    if not args.accept_research_license or ".runtime" not in args.out_dir.parts:
        parser.error(f"Read {LICENSE}; require acknowledgment and ignored .runtime output.")
    samples = calibration_samples(args.corpus)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    if args.mode == "extract":
        if not args.clips or not args.face_model:
            parser.error("Extraction requires --clips and --face-model.")
        if hashlib.sha256(args.face_model.read_bytes()).hexdigest() != FACE_SHA:
            raise ValueError("Unexpected face task.")
    else:
        if not args.model or not args.vocabulary:
            parser.error("Evaluation requires --model and --vocabulary.")
        matcher = PretrainedResearchMatcher(args.model, args.vocabulary)
        matcher.min_score, matcher.min_margin = .4, .05
    counts = {mode: Counter() for mode in ("hands", "hands_face")}
    details, elapsed, present, requested = [], [], 0, 0
    for index, sample in enumerate(samples):
        hand_path = args.hand_cache/(sample["id"]+".json")
        hand_sha = hashlib.sha256(hand_path.read_bytes()).hexdigest()
        frames = json.loads(hand_path.read_text())["frames"]
        cache = args.out_dir/(sample["id"]+".json")
        binding = {"hand_sha256": hand_sha, "face_sha256": FACE_SHA, "rate": args.rate,
                   "corpus_sha256": CORPUS_SHA,
                   "protocol": "face-calibration-fullrate-v2" if args.rate == 24 else "face-calibration-v1"}
        if args.mode == "extract" and not cache.exists():
            data = extract(args.clips/(sample["id"]+".mp4"), args.face_model, frames, args.rate)
            cache.write_text(json.dumps({**binding, **data}, allow_nan=False))
        data = json.loads(cache.read_text())
        if any(data.get(k) != v for k, v in binding.items()):
            raise ValueError("Incompatible cached face extraction; use a new output directory.")
        elapsed += data["inference_ms"]
        requested += len(data["observations"])
        present += sum(valid_face(o["face"]) for o in data["observations"])
        if args.mode == "evaluate":
            predictions = {"hands": set(), "hands_face": set()}
            for window in windows(frames):
                tensor = matcher.tensor(window)
                if tensor is None:
                    continue
                variants = {"hands": tensor,
                            "hands_face": inject_face(tensor, window, data["observations"])}
                for mode, value in variants.items():
                    ranked = ranked_logits(matcher.run(inputs=value)["outputs"].tolist(),
                                           matcher.vocabulary)
                    result = matcher.decide(ranked)
                    label = ranked[0]["label"]
                    if not result["unknown"] and not (label == "NO" and pinch_motion(window) < .075):
                        predictions[mode].add(label)
            truth = sample["label"]
            for mode, labels in predictions.items():
                counts[mode]["clips"] += 1
                counts[mode]["supported_clips"] += truth != "UNKNOWN"
                counts[mode]["correct_raw_clips"] += truth in labels
                counts[mode]["wrong_raw_clips"] += bool(labels-{truth})
                counts[mode]["unsupported_false_clips"] += truth == "UNKNOWN" and bool(labels)
            details.append({"id": sample["id"], "truth": truth,
                            **{m: sorted(v) for m, v in predictions.items()}})
        print(f"{index+1}/{len(samples)} {args.mode}", flush=True)
    report = {"scope": "Original calibration ONLY; raw accepted windows, not UI or phone accuracy.",
              "thresholds": {"score": .4, "margin": .05, "NO_motion": .075},
              "rate": args.rate, "face_requests": requested, "single_face_results": present,
              "face_inference_median_ms": statistics.median(elapsed),
              "face_inference_p95_ms": sorted(elapsed)[int(.95*(len(elapsed)-1))],
              "counts": counts, "clips": details}
    (args.out_dir/(args.mode+"-report.json")).write_text(json.dumps(report, indent=2))
    print(json.dumps({k: v for k, v in report.items() if k != "clips"}, indent=2))


if __name__ == "__main__":
    main()
