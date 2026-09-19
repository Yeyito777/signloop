"""Optional ASL Citizen *local research only* importer (not runtime dependency).

Original data and derived landmarks must not be redistributed or sent to Jev.
Read https://www.microsoft.com/en-us/research/project/asl-citizen/dataset-license/
Delete local data when research ends. Only aggregate results belong in Git.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
from pathlib import Path
import urllib.request
import zipfile

URL = "https://download.microsoft.com/download/b/8/8/b88c0bae-e6c1-43e1-8726-98cf5af36ca4/ASL_Citizen.zip"
LICENSE = "https://www.microsoft.com/en-us/research/project/asl-citizen/dataset-license/"


class RangeReader(io.RawIOBase):
    """Read selected ZIP members, never download the entire 46 GB archive."""
    def __init__(self):
        with urllib.request.urlopen(urllib.request.Request(URL, method="HEAD"), timeout=30) as r:
            self.size = int(r.headers["Content-Length"])
            self.etag = r.headers.get("ETag")
        self.position = 0

    def seekable(self):
        return True

    def tell(self):
        return self.position

    def seek(self, offset, whence=0):
        self.position = offset if whence == 0 else (
            self.position + offset if whence == 1 else self.size + offset)
        if not 0 <= self.position <= self.size:
            raise ValueError("Invalid archive offset.")
        return self.position

    def read(self, size=-1):
        size = min(size if size >= 0 else self.size-self.position, self.size-self.position)
        if not size:
            return b""
        if size > 20_000_000:
            raise ValueError("Refusing archive range over 20 MB.")
        end = self.position + size - 1
        headers = {"Range": f"bytes={self.position}-{end}"}
        if self.etag:
            headers["If-Match"] = self.etag
        with urllib.request.urlopen(urllib.request.Request(URL, headers=headers), timeout=60) as r:
            if r.status != 206 or r.headers.get("Content-Range") != f"bytes {self.position}-{end}/{self.size}":
                raise ValueError("Server did not honor exact byte range.")
            result = r.read(size+1)
        if len(result) != size:
            raise ValueError("Truncated/oversized archive range.")
        self.position += len(result)
        return result


def metadata(archive, folder):
    folder.mkdir(parents=True, exist_ok=True)
    result = {}
    for name in ("train", "val", "test"):
        text = archive.read(f"ASL_Citizen/splits/{name}.csv").decode("utf-8-sig")
        (folder / f"{name}.csv").write_text(text)
        result[name] = list(csv.DictReader(io.StringIO(text)))
    (folder / "use.txt").write_bytes(archive.read("ASL_Citizen/use.txt"))
    return result


def extract_frames(video: Path, model: Path):
    # Optional tooling dependencies; never imported by the runtime server.
    import cv2
    import mediapipe as mp
    cap = cv2.VideoCapture(str(video))
    fps = cap.get(cv2.CAP_PROP_FPS)
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    if not cap.isOpened() or fps <= 0 or total <= 0:
        cap.release()
        raise ValueError("Cannot decode research clip.")
    # Fixed center <=3-second crop, independent of the label or predictions.
    start = max(0, (total - int(3*fps)) // 2)
    end = min(total, start+int(3*fps))
    stride = max(1, round(fps / 15))
    options = mp.tasks.vision.HandLandmarkerOptions(
        base_options=mp.tasks.BaseOptions(model_asset_path=str(model)),
        running_mode=mp.tasks.vision.RunningMode.VIDEO, num_hands=2,
        min_hand_detection_confidence=.55, min_hand_presence_confidence=.55,
        min_tracking_confidence=.55)
    frames = []
    try:
        with mp.tasks.vision.HandLandmarker.create_from_options(options) as tracker:
            cap.set(cv2.CAP_PROP_POS_FRAMES, start)
            for index in range(start, end):
                ok, image = cap.read()
                if not ok:
                    break
                if (index-start) % stride:
                    continue
                # Match the iPhone front-camera convention before detection.
                image = cv2.cvtColor(cv2.flip(image, 1), cv2.COLOR_BGR2RGB)
                height, width = image.shape[:2]
                timestamp = round((index-start)*1000/fps)
                result = tracker.detect_for_video(mp.Image(image_format=mp.ImageFormat.SRGB, data=image),
                                                  timestamp)
                hands = []
                for joints, handedness in zip(result.hand_landmarks, result.handedness):
                    hands.append({"handedness": handedness[0].category_name,
                                  "handednessScore": handedness[0].score,
                                  "joints": [{"x": j.x, "y": j.y, "z": j.z} for j in joints]})
                frames.append({"timestampMS": timestamp, "hands": hands,
                               "imageAspectRatio": width / height, "mirrored": True})
    finally:
        cap.release()
    # Isolated-clip trimming, not a live gesture segmenter.
    visible = [i for i, f in enumerate(frames) if f["hands"]]
    if visible:
        frames = frames[visible[0]:visible[-1]+1]
    return frames


def select_rows(splits, per_label, negatives):
    vocabulary = {"HELLO": "HELLO", "YES": "YES", "NO": "NO",
                  "PLEASE": "PLEASE", "THANKYOU": "THANK_YOU"}
    selected = []
    for split, rows in splits.items():
        output_split = "calibration" if split == "val" else split
        for gloss, label in vocabulary.items():
            matches = [r for r in rows if r["Gloss"] == gloss]
            matches.sort(key=lambda r: hashlib.sha256(r["Video file"].encode()).hexdigest())
            # One recording per signer per label.
            seen = set()
            for row in matches:
                if row["Participant ID"] in seen:
                    continue
                selected.append((output_split, label, row))
                seen.add(row["Participant ID"])
                if len(seen) >= per_label:
                    break
            if not seen:
                raise ValueError(f"No recordings for {gloss} in {split}.")
        if split != "train":
            # Diverse unsupported ASL signs are negatives, NOT nonsigning motion.
            other = [r for r in rows if r["Gloss"] not in vocabulary]
            other.sort(key=lambda r: hashlib.sha256(r["Video file"].encode()).hexdigest())
            seen = set()
            for row in other:
                if row["Gloss"] in seen:
                    continue
                selected.append((output_split, "UNKNOWN", row))
                seen.add(row["Gloss"])
                if len(seen) >= negatives:
                    break
    return selected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--accept-research-license", action="store_true")
    parser.add_argument("--out-dir", type=Path, default=Path(".runtime/asl-citizen"))
    parser.add_argument("--metadata-only", action="store_true")
    parser.add_argument("--per-label", type=int, default=6)
    parser.add_argument("--negatives", type=int, default=15)
    parser.add_argument("--model", type=Path, default=Path("ios/Signloop/Resources/hand_landmarker.task"))
    args = parser.parse_args()
    if not args.accept_research_license:
        parser.error(f"Read {LICENSE}, then explicitly pass --accept-research-license.")
    with zipfile.ZipFile(RangeReader()) as archive:
        splits = metadata(archive, args.out_dir)
        for name, rows in splits.items():
            print(name, len(rows), "columns:", list(rows[0]))
        if args.metadata_only:
            return
        if not 1 <= args.per_label <= 30 or not 1 <= args.negatives <= 100:
            parser.error("Use 1–30 per label and 1–100 negatives per evaluation split.")
        from .matcher import features, load_corpus
        selected = select_rows(splits, args.per_label, args.negatives)
        samples, rejected = [], []
        clips = args.out_dir / "clips"
        clips.mkdir(exist_ok=True)
        cache = args.out_dir / "landmarks"
        cache.mkdir(exist_ok=True)
        for index, (split, label, row) in enumerate(selected):
            filename = row["Video file"]
            # Never trust a remote ZIP name as a local path.
            identifier = hashlib.sha256(filename.encode()).hexdigest()
            video = clips / f"{identifier}.mp4"
            landmarks = cache / f"{identifier}.json"
            if landmarks.exists():
                frames = json.loads(landmarks.read_text())
            else:
                if not video.exists():
                    info = archive.getinfo("ASL_Citizen/videos/" + filename)
                    if info.file_size > 20_000_000:
                        raise ValueError("Refusing clip over 20 MB.")
                    video.write_bytes(archive.read(info))
                frames = extract_frames(video, args.model)
                landmarks.write_text(json.dumps(frames, allow_nan=False))
            if split == "train" and not features(frames):
                rejected.append({"id": identifier, "reason": "unusable_training_tracking"})
            else:
                samples.append({"id": identifier, "label": label, "split": split,
                                "signer": row["Participant ID"], "source": URL,
                                "original_gloss": row["Gloss"], "frames": frames})
            print(f"{index+1}/{len(selected)} {split} {label}: {len(frames)} frames", flush=True)
        corpus = {"version": 1, "dataset": "ASL Citizen official ZIP; local research only",
                  "license": LICENSE, "redistribution": "PROHIBITED",
                  "preprocessing": "MediaPipe 0.10.21 float16 v1; mirrored; 15Hz; center <=3s; no-hand edge trim",
                  "model_sha256": hashlib.sha256(args.model.read_bytes()).hexdigest(),
                  "selection": {"per_label": args.per_label, "negatives_per_split": args.negatives},
                  "rejected_training": rejected, "samples": samples}
        path = args.out_dir / "corpus.json"
        path.write_text(json.dumps(corpus, allow_nan=False))
        load_corpus(path)  # Enforce signer isolation and recording deduplication.
        print(f"Corpus saved locally: {path}. DO NOT COMMIT OR UPLOAD.")


if __name__ == "__main__":
    main()
