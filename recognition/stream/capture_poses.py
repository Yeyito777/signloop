"""Record one signing attempt from a webcam or video file into the pose format the providers consume
(75 MediaPipe Holistic points: 33 pose, 21 left hand, 21 right hand; xy normalized; missing = 0).
Requires mediapipe==0.10.21 and opencv. NOT exercised with a live camera in this repo's test runs.

    python -m recognition.stream.capture_poses --out poses/water__0.pkl [--video clip.mp4] [--seconds 3]
Frames stay on this machine; only landmarks are written.
"""
from __future__ import annotations

import argparse
import pickle
import time

import numpy as np


def landmarks(res):
    out = np.zeros((75, 3), np.float32)
    conf = np.zeros(75, np.float32)
    def fill(lm, start, n):
        if lm is not None:
            for i, p in enumerate(lm.landmark[:n]):
                out[start + i] = (p.x, p.y, p.z)
                conf[start + i] = getattr(p, "visibility", 1.0) or 1.0
    fill(res.pose_landmarks, 0, 33)
    fill(res.left_hand_landmarks, 33, 21)
    fill(res.right_hand_landmarks, 54, 21)
    return out, conf


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--video")
    ap.add_argument("--seconds", type=float, default=3.0)
    a = ap.parse_args()
    import cv2
    import mediapipe as mp
    cap = cv2.VideoCapture(a.video if a.video else 0)
    if not cap.isOpened():
        raise SystemExit("could not open camera/video")
    kps, cfs = [], []
    t0 = time.time()
    with mp.solutions.holistic.Holistic(static_image_mode=False, min_detection_confidence=0.5) as h:
        while True:
            ok, frame = cap.read()
            if not ok or (not a.video and time.time() - t0 > a.seconds):
                break
            k, c = landmarks(h.process(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)))
            kps.append(k)
            cfs.append(c)
    cap.release()
    with open(a.out, "wb") as f:
        pickle.dump({"keypoints": np.stack(kps), "confidences": np.stack(cfs)}, f)
    print(f"wrote {a.out}: {len(kps)} frames")


if __name__ == "__main__":
    main()
