"""Small local temporal coordinate corpus, NOT the full ASL Citizen archive.

Private noncommercial research only. No provider calls, app changes or shared
reference data. Download only planned ZIP members and delete temporary videos.
"""
import argparse
from collections import Counter
import csv
import hashlib
import io
import itertools
import json
from pathlib import Path
import tempfile
import time
import urllib.error
import zipfile

from .research_data import RangeReader, LICENSE, URL
from .research_citizen import METADATA

LABELS = ("HELLO", "YES", "NO", "PLEASE", "THANKYOU", "HELP", "WATER", "MORE",
          "FINISH", "GOOD", "BAD", "NAME", "MY", "SORRY", "STOP", "YOU")
DEMO_LABELS = LABELS + ("ILOVEYOU", "WE", "OUR", "NICE", "MEET", "TODAY", "PROJECT",
                       "TECHNOLOGY", "COMPUTER", "PHONE", "SIGNLANGUAGE", "UNDERSTAND",
                       "LEARN", "SHOW", "MAKE", "CAMERA")
PRESENTATION_LABELS = ("HELLO", "MY", "NAME", "TODAY", "WE", "SHOW", "PHONE",
                       "PLEASE", "SORRY", "THANKYOU", "ILOVEYOU")
LIMITS = {"train": 6, "val": 2, "test": 3}
FACE_IDS = (1, 4, 10, 13, 14, 33, 61, 70, 105, 133, 152, 159, 263, 291, 300, 334, 362, 386)
MODELS = {
    "hand_landmarker": "fbc2a30080c3c557093b5ddfc334698132eb341044ccee322ccf8bcf3607cde1",
    "pose_landmarker_lite": "59929e1d1ee95287735ddd833b19cf4ac46d29bc7afddbbf6753c459690d574a",
    "face_landmarker": "64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff"}
MAX_DOWNLOAD = 150_000_000


def digest(data):
    return hashlib.sha256(data).hexdigest()


class BudgetReader(RangeReader):
    """Range-only server access with a hard per-run byte budget."""
    def __init__(self):
        super().__init__()
        self.bytes_read = 0

    def read(self, size=-1):
        amount = min(size if size >= 0 else self.size-self.position, self.size-self.position)
        for attempt in range(5):
            if self.bytes_read + amount > MAX_DOWNLOAD:
                raise ValueError("150 MB research download budget reached; refuse full archive.")
            # Charge even failed attempts conservatively. The parent only moves
            # the seek position after an exact, complete 206 response.
            self.bytes_read += amount
            try:
                return super().read(size)
            except OSError as error:
                if isinstance(error, urllib.error.HTTPError) and error.code not in (408, 429, 500, 502, 503, 504):
                    raise
                if attempt == 4:
                    raise
                print("Retrying interrupted bounded archive range", flush=True)
                time.sleep(2**attempt) # bounded network backoff, not a model/task polling loop


def select(splits, labels=LABELS):
    participants = {s: {r["Participant ID"] for r in rows} for s, rows in splits.items()}
    for a, b in itertools.combinations(participants, 2):
        if participants[a] & participants[b]:
            raise ValueError("Signer leakage between official splits.")
    samples = []
    for split, count in LIMITS.items():
        rows = sorted(splits[split], key=lambda r: digest(r["Video file"].encode()))
        for label in labels:
            seen = set()
            selected = []
            for row in rows:
                if row["Gloss"] != label or row["Participant ID"] in seen:
                    continue
                seen.add(row["Participant ID"])
                selected.append(row)
                if len(selected) == count:
                    break
            if len(selected) != count:
                raise ValueError(f"Not enough distinct {split} signers for {label}.")
            for row in selected:
                samples.append(sample(row, split, label))
        if split != "train":
            seen = set()
            for row in rows:
                if row["Gloss"] in labels or row["Gloss"] in seen:
                    continue
                seen.add(row["Gloss"])
                samples.append(sample(row, split, "UNKNOWN"))
                if len(seen) == 10:
                    break
            if len(seen) != 10:
                raise ValueError("Not enough unsupported-sign challenges.")
    return samples


def sample(row, split, label):
    filename = row["Video file"]
    if Path(filename).name != filename or "/" in filename or "\\" in filename:
        raise ValueError("Unsafe archive member name.")
    return {"id": digest(filename.encode()), "split": split, "label": label,
            "source_gloss": row["Gloss"], "signer": row["Participant ID"],
            "member": "ASL_Citizen/videos/"+filename}


def plan(archive, etag, labels=LABELS):
    splits = {}
    for split, expected in METADATA.items():
        text = archive.read(f"ASL_Citizen/splits/{split}.csv").decode("utf-8-sig")
        if digest(text.encode()) != expected:
            raise ValueError("Official metadata changed.")
        splits[split] = list(csv.DictReader(io.StringIO(text)))
    samples = select(splits, labels)
    for row in samples:
        info = archive.getinfo(row["member"])
        if not 0 < info.file_size <= 20_000_000:
            raise ValueError("Oversized clip; no silent omission.")
        row.update(zip_crc32=info.CRC, compressed_bytes=info.compress_size, video_bytes=info.file_size)
    total = sum(s["compressed_bytes"] for s in samples)
    limit = 220_000_000 if tuple(labels) == DEMO_LABELS else 110_000_000
    if total > limit:
        raise ValueError("Planned clips exceed vocabulary-specific budget; review before downloading.")
    return {"version": 1, "source": URL, "license": LICENSE, "source_etag": etag,
            "labels": labels, "per_label": LIMITS, "samples": samples,
            "clip_compressed_bytes": total, "models": MODELS, "mediapipe": "0.10.21",
            "sampling": "full clip, 15 Hz nearest source-frame cadence; no gesture trim",
            "coordinates": "unmirrored source image normalized x/y; model-local z; width/height retained",
            "face_ids": FACE_IDS, "scope": "Private research subset; not continuous signing or natural nonsigning",
            "retention": "No new video cache; delete temporary input after each clip. Private derivatives only."}


def hand_sides(hands, pose, pose_valid, aspect):
    """Match Swift SkeletonFrame: optional one-to-one wrists, .20/.01 costs."""
    import numpy as np
    wrists = [15, 16]
    options = []
    for assignment in itertools.product((-1, 0, 1), repeat=len(hands)):
        known = [s for s in assignment if s >= 0]
        if len(known) != len(set(known)):
            continue
        cost = 0.
        for hand, side in zip(hands, assignment):
            if side < 0:
                cost += .20
            elif not pose_valid[wrists[side]]:
                cost = float("inf")
            else:
                delta = hand[0, :2]-pose[wrists[side], :2]
                cost += float(np.hypot(delta[0]*aspect, delta[1]))
        options.append((cost, assignment))
    options.sort()
    if not options or not np.isfinite(options[0][0]) or (len(options) > 1 and options[1][0]-options[0][0] < .01):
        return [-1]*len(hands)
    return list(options[0][1])


def extraction(video, models):
    import cv2
    import mediapipe as mp
    import numpy as np
    if mp.__version__ != "0.10.21":
        raise ValueError("Use MediaPipe 0.10.21 to match app.")
    vision = mp.tasks.vision
    base = lambda name: mp.tasks.BaseOptions(model_asset_path=str(models/(name+".task")))
    h = vision.HandLandmarkerOptions(base_options=base("hand_landmarker"),
        running_mode=vision.RunningMode.VIDEO, num_hands=2, min_hand_detection_confidence=.55,
        min_hand_presence_confidence=.55, min_tracking_confidence=.55)
    p = vision.PoseLandmarkerOptions(base_options=base("pose_landmarker_lite"),
        running_mode=vision.RunningMode.VIDEO, num_poses=1, min_pose_detection_confidence=.5,
        min_pose_presence_confidence=.5, min_tracking_confidence=.5, output_segmentation_masks=False)
    f = vision.FaceLandmarkerOptions(base_options=base("face_landmarker"),
        running_mode=vision.RunningMode.VIDEO, num_faces=1, min_face_detection_confidence=.5,
        min_face_presence_confidence=.5, min_tracking_confidence=.5, output_face_blendshapes=True)
    cap = cv2.VideoCapture(str(video))
    fps, count = cap.get(cv2.CAP_PROP_FPS), int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    if not cap.isOpened() or not 1 <= fps <= 120 or not 1 <= count <= 2000:
        cap.release()
        raise ValueError("Invalid/oversized clip.")
    rows, blend_names, deadline, last_ms = [], None, 0., -1
    began = time.perf_counter()
    try:
        with vision.HandLandmarker.create_from_options(h) as hand, \
             vision.PoseLandmarker.create_from_options(p) as body, \
             vision.FaceLandmarker.create_from_options(f) as face:
            for index in range(count):
                ok, bgr = cap.read()
                if not ok:
                    raise ValueError("Truncated video; no silent sample omission.")
                t = index/fps
                if t+1e-9 < deadline:
                    continue
                deadline += (int((t-deadline)*15+1e-9)+1)/15
                timestamp = round(t*1000)
                if timestamp <= last_ms:
                    raise ValueError("Non-increasing frame timestamps.")
                last_ms = timestamp
                image = mp.Image(image_format=mp.ImageFormat.SRGB, data=cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB))
                hr = hand.detect_for_video(image, timestamp)
                pr = body.detect_for_video(image, timestamp)
                fr = face.detect_for_video(image, timestamp)
                hp, pp, fp = np.zeros((2, 21, 3)), np.zeros((25, 3)), np.zeros((len(FACE_IDS), 3))
                hv, pv = np.zeros(2, bool), np.zeros(25, bool)
                confidence = np.zeros((25, 2))
                expressions = {}
                for i, landmarks in enumerate(hr.hand_landmarks):
                    hp[i] = [[v.x, v.y, v.z] for v in landmarks]
                    hv[i] = True
                if pr.pose_landmarks:
                    for i, v in enumerate(pr.pose_landmarks[0][:25]):
                        pp[i] = v.x, v.y, v.z
                        confidence[i] = [v.visibility if v.visibility is not None else 1.,
                                         v.presence if v.presence is not None else 1.]
                        pv[i] = np.isfinite(pp[i]).all() and min(confidence[i]) >= .5
                if fr.face_landmarks:
                    fp[:] = [[fr.face_landmarks[0][i].x, fr.face_landmarks[0][i].y,
                              fr.face_landmarks[0][i].z] for i in FACE_IDS]
                    expressions = {c.category_name: float(c.score) for c in fr.face_blendshapes[0]}
                    names = sorted(expressions)
                    if len(names) != 52 or (blend_names is not None and blend_names != names):
                        raise ValueError("Unexpected face blendshape schema.")
                    blend_names = names
                sides = np.full(2, -1, dtype=np.int8)
                sides[:len(hr.hand_landmarks)] = hand_sides(hp[:len(hr.hand_landmarks)], pp, pv, bgr.shape[1]/bgr.shape[0])
                for points in (hp, pp, fp, confidence):
                    if not np.isfinite(points).all():
                        raise ValueError("Non-finite observations.")
                rows.append((timestamp, hp, hv, sides, pp, pv, confidence, fp, bool(fr.face_landmarks), expressions))
    finally:
        cap.release()
    # No face in the entire clip: retain explicit missing mask, no invented channels.
    names = blend_names or []
    result = {
        "timestamp_ms": np.array([r[0] for r in rows], dtype=np.int32),
        "hands": np.array([r[1] for r in rows], dtype=np.float32),
        "hand_valid": np.array([r[2] for r in rows]),
        "hand_sides": np.array([r[3] for r in rows], dtype=np.int8),
        "pose": np.array([r[4] for r in rows], dtype=np.float32),
        "pose_valid": np.array([r[5] for r in rows]),
        "pose_confidence": np.array([r[6] for r in rows], dtype=np.float32),
        "face_anchors": np.array([r[7] for r in rows], dtype=np.float32),
        "face_valid": np.array([r[8] for r in rows]),
        "blendshapes": np.array([[r[9].get(n, 0.) for n in names] for r in rows], dtype=np.float32),
        "blendshape_names": np.array(names, dtype="U32"), "face_ids": np.array(FACE_IDS, dtype=np.int16),
        "width": np.array(bgr.shape[1]), "height": np.array(bgr.shape[0]), "source_fps": np.array(fps)}
    stats = {"frames": len(rows), "hands_frames": int(result["hand_valid"].any(axis=1).sum()),
             "pose_frames": int(result["pose_valid"][:, [11, 12]].all(axis=1).sum()),
             "face_frames": int(result["face_valid"].sum()), "elapsed_seconds": round(time.perf_counter()-began, 2)}
    return result, stats


def reused_coordinates(folder, row, planned):
    """Reuse an exactly bound sample, never relabel or silently mix trackers."""
    import numpy as np
    from .basic_corpus import validate_arrays
    path = folder/"plan.json"
    old = json.loads(path.read_text())
    binding = digest(path.read_bytes())
    report = json.loads((folder/"report.json").read_text())
    if not report["complete"] or report["plan_sha256"] != binding:
        raise ValueError("Coordinate source is incomplete or unbound.")
    for key in ("source", "source_etag", "models", "mediapipe", "sampling", "coordinates", "face_ids"):
        if old[key] != planned[key]:
            raise ValueError("Coordinate source pipeline differs.")
    original = next((s for s in old["samples"] if s["id"] == row["id"]), None)
    if original is None:
        return None
    if original != row:
        # A formerly unsupported sign becoming supported must be re-evaluated
        # deliberately, not silently reassigned through this reuse path.
        return None
    with np.load(folder/"coordinates"/(row["id"]+".npz"), allow_pickle=False) as stored:
        arrays = {k: stored[k] for k in stored.files}
    if str(arrays["plan_sha256"]) != binding:
        raise ValueError("Coordinate source binding mismatch.")
    validate_arrays(arrays)
    return arrays


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("plan", "extract"))
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--models", type=Path, default=Path("ios/Signloop/Resources"))
    parser.add_argument("--cache", type=Path, nargs="*", default=[])
    parser.add_argument("--vocabulary", choices=("basic16", "demo32", "presentation11"), default="basic16")
    parser.add_argument("--coordinate-cache", type=Path)
    parser.add_argument("--accept-research-license", action="store_true")
    args = parser.parse_args()
    if not args.accept_research_license or ".runtime" not in args.out.resolve().parts:
        parser.error(f"Read {LICENSE}; require private .runtime output and explicit research acknowledgment.")
    args.out.mkdir(parents=True, exist_ok=True, mode=0o700)
    args.out.chmod(0o700)
    reader = BudgetReader()
    with zipfile.ZipFile(reader) as archive:
        labels = {"demo32": DEMO_LABELS, "presentation11": PRESENTATION_LABELS, "basic16": LABELS}[args.vocabulary]
        planned = plan(archive, reader.etag, labels)
        planned = json.loads(json.dumps(planned))
        plan_path = args.out/"plan.json"
        if plan_path.exists() and json.loads(plan_path.read_text()) != planned:
            raise ValueError("Frozen plan changed; refuse to mix datasets.")
        if not plan_path.exists():
            plan_path.write_text(json.dumps(planned, indent=2))
        (args.out/"use.txt").write_bytes(archive.read("ASL_Citizen/use.txt"))
        print("PLAN", len(planned["samples"]), "clips;", len(labels), "signs;",
              round(planned["clip_compressed_bytes"]/1e6, 2), "MB maximum selected video payload", flush=True)
        if args.action == "plan":
            print("Range bytes downloaded (metadata/index only):", reader.bytes_read)
            return
        import numpy as np
        for name, expected in MODELS.items():
            if digest((args.models/(name+".task")).read_bytes()) != expected:
                raise ValueError("Tracker model hash mismatch.")
        plan_sha = digest(plan_path.read_bytes())
        records = []
        output = args.out/"coordinates"
        output.mkdir(exist_ok=True)
        for i, sample in enumerate(planned["samples"]):
            target = output/(sample["id"]+".npz")
            if not target.exists() and args.coordinate_cache:
                reused = reused_coordinates(args.coordinate_cache, sample, planned)
                if reused is not None:
                    reused["plan_sha256"] = np.array(plan_sha)
                    temporary = target.with_suffix(".partial.npz")
                    np.savez_compressed(temporary, **reused)
                    temporary.replace(target)
            if target.exists():
                with np.load(target, allow_pickle=False) as data:
                    if str(data["plan_sha256"]) != plan_sha:
                        raise ValueError("Cached coordinates belong to a different plan.")
                    stats = json.loads(str(data["stats"]))
            else:
                cached = next((root/(sample["id"]+".mp4") for root in args.cache
                               if (root/(sample["id"]+".mp4")).is_file()), None)
                # Only own temporary video is removed. Existing research caches are read-only.
                with tempfile.TemporaryDirectory(dir=args.out, prefix="input-") as directory:
                    video = cached or Path(directory)/"clip.mp4"
                    if cached is None:
                        video.write_bytes(archive.read(sample["member"]))
                    raw = video.read_bytes()
                    import zlib
                    if len(raw) != sample["video_bytes"] or zlib.crc32(raw) != sample["zip_crc32"]:
                        raise ValueError("Video fails archive size/CRC binding.")
                    arrays, stats = extraction(video, args.models)
                    arrays.update(plan_sha256=np.array(plan_sha), source_sha256=np.array(digest(raw)),
                                  stats=np.array(json.dumps(stats)))
                    temporary = target.with_suffix(".partial.npz")
                    np.savez_compressed(temporary, **arrays)
                    temporary.replace(target)
            records.append({k: sample[k] for k in ("id", "label", "split", "signer")} | stats)
            print(f"{i+1}/{len(planned['samples'])} {sample['split']} {sample['label']} {stats['frames']} frames", flush=True)
            report = {"complete": len(records) == len(planned["samples"]), "plan_sha256": plan_sha,
                      "clips": len(records), "labels": labels, "counts": dict(Counter(r["split"] for r in records)),
                      "coordinate_bytes": sum(p.stat().st_size for p in output.glob("*.npz") if ".partial." not in p.name),
                      "this_run_range_bytes": reader.bytes_read, "rows": records}
            (args.out/"report.json").write_text(json.dumps(report, indent=2))
        print(json.dumps({k: v for k, v in report.items() if k != "rows"}, indent=2))


if __name__ == "__main__":
    main()
