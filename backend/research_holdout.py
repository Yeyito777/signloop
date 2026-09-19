"""Frozen additional-clip evaluation preparation, local restricted research only.

Does not infer the learned sign model or tune any policy. No uploads. Freeze
metadata selection before downloading frames; retain all tracking failures.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
from pathlib import Path
import zipfile

from .research_data import RangeReader, LICENSE
from .research_static import MODEL_SHA

VOCAB = {"HELLO": "HELLO", "YES": "YES", "NO": "NO", "PLEASE": "PLEASE",
         "THANKYOU": "THANK_YOU", "ILOVEYOU": "I_LOVE_YOU"}
POLICY_FILES = ("Recognition.swift", "PretrainedSignPolicy.swift", "PretrainedSignEngine.swift",
                "LiveWindowPolicy.swift", "CaptureCadence.swift")


def identifier(row):
    return hashlib.sha256(row["Video file"].encode()).hexdigest()


def select(rows, prior_ids, negatives_per_signer=3):
    used_signers = {r["Participant ID"] for r in rows if identifier(r) in prior_ids}
    unseen = sorted((r for r in rows if identifier(r) not in prior_ids), key=identifier)
    positive = [{"row": r, "label": VOCAB[r["Gloss"]],
                 "group": "additional_supported", "new_signer": r["Participant ID"] not in used_signers}
                for r in unseen if r["Gloss"] in VOCAB]
    counts, glosses, negative = {}, set(), []
    for row in unseen:
        signer, gloss = row["Participant ID"], row["Gloss"]
        if signer in used_signers or gloss in VOCAB or gloss in glosses:
            continue
        if counts.get(signer, 0) >= negatives_per_signer:
            continue
        negative.append({"row": row, "label": "UNKNOWN", "group": "unused_signer_negatives",
                         "new_signer": True})
        counts[signer] = counts.get(signer, 0)+1
        glosses.add(gloss)
    return sorted(positive+negative, key=lambda sample: identifier(sample["row"]))


class Cadence:
    """Exact arithmetic policy of native CaptureCadence (24Hz target)."""
    def __init__(self):
        self.deadline = None

    def admit(self, time):
        period = 1/24
        if self.deadline is None:
            self.deadline = time+period
            return True
        if time+1e-9 < self.deadline:
            return False
        self.deadline = time+period if time-self.deadline > period else self.deadline+period
        return True


def observe(video, model):
    import cv2
    import mediapipe as mp
    if mp.__version__ != "0.10.21":
        raise ValueError("Use the pinned MediaPipe 0.10.21 research environment.")
    cap = cv2.VideoCapture(str(video))
    fps, total = cap.get(cv2.CAP_PROP_FPS), int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    if not cap.isOpened() or fps <= 0 or total <= 0:
        cap.release()
        raise ValueError("Cannot decode clip; do not silently omit.")
    start = max(0, (total-int(3*fps))//2)
    end = min(total, start+int(3*fps))
    options = mp.tasks.vision.GestureRecognizerOptions(
        base_options=mp.tasks.BaseOptions(model_asset_path=str(model)),
        running_mode=mp.tasks.vision.RunningMode.VIDEO, num_hands=2,
        min_hand_detection_confidence=.55, min_hand_presence_confidence=.55,
        min_tracking_confidence=.55,
        canned_gesture_classifier_options=mp.tasks.components.processors.ClassifierOptions(max_results=2))
    frames, gestures = [], []
    cadence = Cadence()
    try:
        with mp.tasks.vision.GestureRecognizer.create_from_options(options) as recognizer:
            cap.set(cv2.CAP_PROP_POS_FRAMES, start)
            for index in range(start, end):
                ok, image = cap.read()
                if not ok:
                    raise ValueError("Truncated research video; do not silently omit.")
                time = (index-start)/fps
                if not cadence.admit(time):
                    continue
                image = cv2.cvtColor(cv2.flip(image, 1), cv2.COLOR_BGR2RGB)
                height, width = image.shape[:2]
                timestamp = round(time*1000)
                result = recognizer.recognize_for_video(
                    mp.Image(image_format=mp.ImageFormat.SRGB, data=image), timestamp)
                hands = [{"handedness": categories[0].category_name,
                          "handednessScore": categories[0].score,
                          "joints": [{"x": p.x, "y": p.y, "z": p.z} for p in joints]}
                         for joints, categories in zip(result.hand_landmarks, result.handedness)]
                estimates = []
                for categories in result.gestures:
                    ranked = sorted(categories, key=lambda c: -c.score)
                    estimates.append({"label": ranked[0].category_name if ranked else "None",
                                      "score": ranked[0].score if ranked else 0,
                                      "runner": ranked[1].score if len(ranked) > 1 else 0})
                frames.append({"timestampMS": timestamp, "hands": hands,
                               "imageAspectRatio": width/height, "mirrored": True})
                gestures.append(estimates if len(estimates) == len(hands) else [])
    finally:
        cap.release()
    # Do not trim no-hand frames or drop clips with poor/no tracking.
    return {"frames": frames, "gestures": gestures, "source_fps": fps}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--accept-research-license", action="store_true")
    parser.add_argument("--metadata-dir", type=Path, required=True)
    parser.add_argument("--prior-clips", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, default=Path(".runtime/frozen-holdout"))
    parser.add_argument("--plan-only", action="store_true")
    args = parser.parse_args()
    if not args.accept_research_license or ".runtime" not in args.out_dir.parts:
        parser.error(f"Read {LICENSE}; pass --accept-research-license and use an ignored .runtime output.")
    if hashlib.sha256(args.model.read_bytes()).hexdigest() != MODEL_SHA:
        parser.error("Unrecognized gesture model.")
    policy_root = Path(__file__).resolve().parent.parent/"ios/Signloop"
    policy_hashes = {n: hashlib.sha256((policy_root/n).read_bytes()).hexdigest() for n in POLICY_FILES}
    args.out_dir.mkdir(parents=True, exist_ok=True)
    plan_file = args.out_dir/"plan.json"
    if plan_file.exists():
        plan = json.loads(plan_file.read_text())
        if plan["policy_sha256"] != policy_hashes:
            raise ValueError("Policy changed since selection; preserve report and do not silently retune.")
    else:
        files = [args.metadata_dir/(s+".csv") for s in ("train", "val", "test")]
        rows = [r for p in files for r in csv.DictReader(p.open())]
        prior = {p.stem for p in args.prior_clips.glob("*.mp4")}
        if not prior:
            raise ValueError("Prior-use cache required to avoid false fresh-data claims.")
        plan = {"policy_sha256": policy_hashes, "gesture_model_sha256": MODEL_SHA,
                "metadata_sha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in files},
                "prior_clip_ids": sorted(prior),
                "samples": select(rows, prior),
                "scope": "New-to-this-project clips; supported signers may have appeared earlier. "
                         "Unsupported signs from unused participants are NOT natural nonsigning. "
                         "Pretrained training overlap is not independently excluded.",
                "protocol": "center <=3s, untrimmed, mirrored, 24Hz deadline gate; "
                            "frozen 250ms learned worker + separate ILY UI-priority filter"}
        # Exclusive creation ensures selection is frozen before any frame read.
        with plan_file.open("x") as stream:
            json.dump(plan, stream, indent=2)
    samples = plan["samples"]
    print(json.dumps({"selected_clips": len(samples),
                      "supported": sum(s["label"] != "UNKNOWN" for s in samples),
                      "unsupported": sum(s["label"] == "UNKNOWN" for s in samples),
                      "unused_negative_signers": len({s["row"]["Participant ID"] for s in samples if s["label"] == "UNKNOWN"}),
                      "fresh_positive_signers": len({s["row"]["Participant ID"] for s in samples if s["label"] != "UNKNOWN" and s["new_signer"]})}), flush=True)
    if args.plan_only:
        return
    cache = args.out_dir/"observations"
    clips = args.out_dir/"clips"
    cache.mkdir(exist_ok=True)
    clips.mkdir(exist_ok=True)
    replay = []
    with zipfile.ZipFile(RangeReader()) as archive:
        for i, sample in enumerate(samples):
            row = sample["row"]
            name = identifier(row)
            cached = cache/(name+".json")
            if cached.exists():
                observed = json.loads(cached.read_text())
            else:
                video = clips/(name+".mp4")
                if not video.exists():
                    info = archive.getinfo("ASL_Citizen/videos/"+row["Video file"])
                    if info.file_size > 20_000_000:
                        raise ValueError("Oversized research clip")
                    video.write_bytes(archive.read(info))
                observed = observe(video, args.model)
                cached.write_text(json.dumps(observed, allow_nan=False))
            replay.append({"split": sample["group"], "label": sample["label"], **observed})
            print(f"{i+1}/{len(samples)} processed", flush=True)
    (args.out_dir/"live-replay-fixture.json").write_text(json.dumps({
        "source": "LOCAL_RESEARCH_ONLY_ASL_CITIZEN", "clips": replay,
        "plan_sha256": hashlib.sha256(plan_file.read_bytes()).hexdigest()}, allow_nan=False))


if __name__ == "__main__":
    main()
