"""Frozen pretrained ILY-handshape evaluation. Local restricted research ONLY.

No training on ASL Citizen; no data goes to a model API. Outputs/inputs stay
under .runtime; only aggregate results may be published. Not full ASL accuracy.
"""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import time
import zipfile

from .research_data import RangeReader, URL, LICENSE

MODEL_SHA = "97952348cf6a6a4915c2ea1496b4b37ebabc50cbbf80571435643c455f2b0482"


def accepted(label, score, runner):
    return (label == "ILoveYou" and 0 <= score <= 1 and 0 <= runner <= 1
            and score >= .85 and score - runner >= .2)


def filter_frames(frames):
    """Contract mirrored by the Swift LocalGestureFilter tests."""
    since = None
    last = None
    count = 0
    matched = []
    for frame in frames:
        timestamp = frame["timestampMS"]
        hands = frame["hands"]
        if timestamp < 0:
            since, last, count = None, None, 0
            matched.append(False)
            continue
        if last is None or timestamp <= last or timestamp-last > 150:
            since, count = None, 0
        last = timestamp
        # Only a single-hand gesture, not interpretation of compound signs.
        candidate = hands[0] if len(hands) == 1 else None
        if candidate and accepted(candidate["label"], candidate["score"], candidate["runner"]):
            if since is None:
                since = timestamp
            count += 1
            matched.append(count >= 3 and timestamp-since >= 150)
        else:
            since, count = None, 0
            matched.append(False)
    return matched


def observe(video, model):
    import cv2
    import mediapipe as mp
    cap = cv2.VideoCapture(str(video))
    fps, total = cap.get(cv2.CAP_PROP_FPS), int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    if not cap.isOpened() or fps <= 0 or total <= 0:
        raise ValueError("Cannot decode clip.")
    start = max(0, (total-int(3*fps))//2)
    end = min(total, start+int(3*fps))
    stride = max(1, round(fps/15))
    options = mp.tasks.vision.GestureRecognizerOptions(
        base_options=mp.tasks.BaseOptions(model_asset_path=str(model)),
        running_mode=mp.tasks.vision.RunningMode.VIDEO, num_hands=2,
        min_hand_detection_confidence=.55, min_hand_presence_confidence=.55,
        min_tracking_confidence=.55,
        canned_gesture_classifier_options=mp.tasks.components.processors.ClassifierOptions(max_results=2))
    frames, latencies = [], []
    try:
        with mp.tasks.vision.GestureRecognizer.create_from_options(options) as recognizer:
            cap.set(cv2.CAP_PROP_POS_FRAMES, start)
            for index in range(start, end):
                ok, image = cap.read()
                if not ok:
                    break
                if (index-start) % stride:
                    continue
                image = cv2.cvtColor(cv2.flip(image, 1), cv2.COLOR_BGR2RGB)
                timestamp = round((index-start)*1000/fps)
                before = time.perf_counter()
                result = recognizer.recognize_for_video(
                    mp.Image(image_format=mp.ImageFormat.SRGB, data=image), timestamp)
                latencies.append(1000*(time.perf_counter()-before))
                hands = []
                for categories in result.gestures:
                    ranked = sorted(categories, key=lambda c: c.score, reverse=True)
                    if ranked:
                        hands.append({"label": ranked[0].category_name, "score": ranked[0].score,
                                      "runner": ranked[1].score if len(ranked) > 1 else 0})
                frames.append({"timestampMS": timestamp, "hands": hands})
    finally:
        cap.release()
    return frames, latencies


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--accept-research-license", action="store_true")
    parser.add_argument("--dataset-dir", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, default=Path(".runtime/static-evaluation"))
    args = parser.parse_args()
    if not args.accept_research_license:
        parser.error(f"Read {LICENSE} and pass --accept-research-license.")
    if hashlib.sha256(args.model.read_bytes()).hexdigest() != MODEL_SHA:
        parser.error("Model SHA-256 mismatch.")
    # Frozen policy, no threshold search. Test positive samples selected from
    # metadata only; one clip per signer, deterministic filename-hash ordering.
    metadata = list(csv.DictReader((args.dataset_dir / "test.csv").open()))
    positives = sorted([r for r in metadata if r["Gloss"] == "ILOVEYOU"],
                       key=lambda r: hashlib.sha256(r["Video file"].encode()).hexdigest())
    seen, selected = set(), []
    for row in positives:
        if row["Participant ID"] not in seen:
            selected.append((hashlib.sha256(row["Video file"].encode()).hexdigest(),
                             True, row["Participant ID"], row["Video file"]))
            seen.add(row["Participant ID"])
    negative_ids = set()
    for corpus_name in ("corpus.json", "corpus-v2.json"):
        corpus = json.loads((args.dataset_dir / corpus_name).read_text())
        for sample in corpus["samples"]:
            if sample["split"] != "test" or sample["id"] in negative_ids:
                continue
            if sample["original_gloss"] == "ILOVEYOU":
                continue
            selected.append((sample["id"], False, sample["signer"], None))
            negative_ids.add(sample["id"])
    args.out_dir.mkdir(parents=True, exist_ok=True)
    results, latencies = [], []
    with zipfile.ZipFile(RangeReader()) as archive:
        for index, (identifier, truth, signer, filename) in enumerate(selected):
            video = args.dataset_dir / "clips" / (identifier + ".mp4")
            if not video.exists():
                if filename is None:
                    raise ValueError("Cached negative clip missing.")
                info = archive.getinfo("ASL_Citizen/videos/" + filename)
                if info.file_size > 20_000_000:
                    raise ValueError("Clip exceeds download limit.")
                video.write_bytes(archive.read(info))
            cache = args.out_dir / (identifier + ".json")
            if cache.exists():
                cached = json.loads(cache.read_text())
                frames, elapsed = cached["frames"], cached["latencies"]
            else:
                frames, elapsed = observe(video, args.model)
                cache.write_text(json.dumps({"frames": frames, "latencies": elapsed}))
            matches = filter_frames(frames)
            results.append({"id": identifier, "signer": signer, "truth_ily": truth,
                            "detected": any(matches), "frames": frames,
                            "swift_expected": matches})
            latencies.extend(elapsed)
            print(f"{index+1}/{len(selected)} processed", flush=True)
    positive = [r for r in results if r["truth_ily"]]
    negative = [r for r in results if not r["truth_ily"]]
    summary = {
        "model_sha256": MODEL_SHA, "source": URL, "license": LICENSE,
        "scope": "Frozen pretrained single-hand ILY handshape. Isolated research clips; NOT live ASL validation.",
        "policy": {"threshold": .85, "margin": .2, "hold_ms": 150, "max_gap_ms": 150,
                   "min_frames": 3, "one_hand_only": True},
        "positive_clips": len(positive), "positive_signers": len({r["signer"] for r in positive}),
        "positive_detected": sum(r["detected"] for r in positive),
        "negative_clips": len(negative), "negative_false_accepts": sum(r["detected"] for r in negative),
        "mean_model_ms": sum(latencies)/len(latencies),
        "note": "A positive means any stable detection inside the center <=3-second clip. No negative clips removed for poor tracking.",
    }
    (args.out_dir / "summary.json").write_text(json.dumps(summary, indent=2))
    (args.out_dir / "replay.json").write_text(json.dumps(results))
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
