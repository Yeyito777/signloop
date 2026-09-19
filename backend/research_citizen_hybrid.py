"""Controlled local ablation: Tasks hands + original Holistic body for ST-GCN.

No retraining, frame drops or app changes. Match hand wrists geometrically to
pose wrists in the same unmirrored image; never infer anatomy from array order.
"""
import argparse
import itertools
import json
from pathlib import Path
import time

from .research_citizen import sha
from .research_data import LICENSE
from .research_static import MODEL_SHA


def associate(pose, hands, maximum_distance=.25):
    import numpy as np
    if pose.shape != (75, 2) or not np.isfinite(pose).all():
        raise ValueError("Expected finite upstream pose.")
    if len(hands) > 2 or any(h.shape != (21, 2) or not np.isfinite(h).all() for h in hands):
        raise ValueError("Expected at most two finite 21-point hands.")
    output = pose.copy()
    output[33:] = 0
    if not hands:
        return output
    wrists = [pose[16], pose[15]]  # physical right, physical left
    assignments = list(itertools.permutations(range(2), len(hands)))
    ranked = sorted((sum(float(np.linalg.norm(hands[i][0]-wrists[side]))
                         for i, side in enumerate(a)), a) for a in assignments)
    if len(ranked) > 1 and ranked[1][0]-ranked[0][0] < .01:
        return output  # ambiguous anatomy is missing, not an array-order guess
    assignment = ranked[0][1]
    for i, side in enumerate(assignment):
        if np.any(wrists[side]) and np.linalg.norm(hands[i][0]-wrists[side]) <= maximum_distance:
            start = 33 if side == 0 else 54
            output[start:start+21] = hands[i]
    return output


def extract(video, task, body, fps):
    import cv2
    import mediapipe as mp
    import numpy as np
    if mp.__version__ != "0.10.21":
        raise ValueError("Pinned MediaPipe 0.10.21 required.")
    cap = cv2.VideoCapture(str(video))
    if (not cap.isOpened() or int(cap.get(cv2.CAP_PROP_FRAME_COUNT)) != len(body) or
            abs(cap.get(cv2.CAP_PROP_FPS)-fps) > .001):
        cap.release()
        raise ValueError("Video/body cache alignment mismatch.")
    options = mp.tasks.vision.GestureRecognizerOptions(
        base_options=mp.tasks.BaseOptions(model_asset_path=str(task)),
        running_mode=mp.tasks.vision.RunningMode.VIDEO, num_hands=2,
        min_hand_detection_confidence=.55, min_hand_presence_confidence=.55,
        min_tracking_confidence=.55)
    data, timings, detected = [], [], []
    try:
        with mp.tasks.vision.GestureRecognizer.create_from_options(options) as recognizer:
            for index, pose in enumerate(body):
                ok, image = cap.read()
                if not ok:
                    raise ValueError("Truncated source; no silent sample omissions.")
                image = cv2.cvtColor(image, cv2.COLOR_BGR2RGB)
                began = time.perf_counter()
                result = recognizer.recognize_for_video(
                    mp.Image(image_format=mp.ImageFormat.SRGB, data=image), round(index/fps*1000))
                timings.append((time.perf_counter()-began)*1000)
                hands = [np.array([[p.x, p.y] for p in landmarks], dtype=np.float64)
                         for landmarks in result.hand_landmarks]
                data.append(associate(pose, hands))
                detected.append(len(hands))
    finally:
        cap.release()
    return np.asarray(data), timings, detected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--task", type=Path, required=True)
    parser.add_argument("--accept-research-license", action="store_true")
    args = parser.parse_args()
    if not args.accept_research_license or ".runtime" not in args.out.parts:
        parser.error(f"Read {LICENSE}; require explicit acknowledgment and ignored output.")
    if sha(args.task) != MODEL_SHA or args.source.resolve() == args.out.resolve():
        raise ValueError("Require official hand task and a separate output directory.")
    import numpy as np
    source_plan = args.source/"plan.json"
    plan = json.loads(source_plan.read_text()) | {
        "tracking": "tasks-hands+holistic-body-v1", "hand_task_sha256": MODEL_SHA,
        "association": "unique minimum wrist distance, <=.25 image units, cost gap >=.01; no handedness-label heuristic",
        "source_plan_sha256": sha(source_plan)}
    args.out.mkdir(parents=True, exist_ok=True)
    plan_path = args.out/"plan.json"
    if plan_path.exists():
        if json.loads(plan_path.read_text()) != plan:
            raise ValueError("Ablation plan changed.")
    else:
        with plan_path.open("x") as stream:
            json.dump(plan, stream, indent=2)
    (args.out/"poses").mkdir(exist_ok=True)
    for index, sample in enumerate(plan["samples"]):
        output = args.out/"poses"/(sample["id"]+".npz")
        source = args.source/"poses"/(sample["id"]+".npz")
        binding = sha(source)
        if output.exists():
            with np.load(output, allow_pickle=False) as stored:
                if str(stored["source_sha256"]) != binding:
                    raise ValueError("Body cache changed.")
        else:
            if sha(sample["video"]) != sample["video_sha256"]:
                raise ValueError("Video changed.")
            with np.load(source, allow_pickle=False) as stored:
                body, fps = stored["data"], float(stored["fps"])
                if str(stored["video_sha256"]) != sample["video_sha256"]:
                    raise ValueError("Source cache mismatch.")
            data, timings, detected = extract(sample["video"], args.task, body, fps)
            assert np.array_equal(data[:, :33], body[:, :33]), "Body coordinates changed"
            np.savez_compressed(output, data=data, fps=fps, timings=timings, detected=detected,
                                source_sha256=binding, video_sha256=sample["video_sha256"])
        print(f"hybrid {index+1}/{len(plan['samples'])}", flush=True)


if __name__ == "__main__":
    main()
