"""Swift articulation parity. Optional restricted research data stays temporary/local."""
import argparse
import copy
import json
from pathlib import Path
import struct
import subprocess
import tempfile

from .matcher import load_corpus
from .research_motion import pinch_motion, challenges
from .stream_replay import replay_clip
from .test_motion import articulation


def f32(value):
    return struct.unpack("f", struct.pack("f", value))[0]


def query(window):
    # Native landmarks are Float: compare using the same input precision.
    frames = copy.deepcopy(window)
    for frame in frames:
        if "imageAspectRatio" in frame:
            frame["imageAspectRatio"] = f32(frame["imageAspectRatio"])
        for hand in frame["hands"]:
            hand.setdefault("handednessScore", .5)
            for point in hand["joints"]:
                for axis in ("x", "y", "z"):
                    point[axis] = f32(point[axis])
    return {"frames": frames, "motion": pinch_motion(frames)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path)
    args = parser.parse_args()
    base = articulation()
    windows = [[], base, base[:5]]
    for kind in ("gap", "missing", "duplicate", "spike", "mirror", "aspect", "degenerate"):
        data = copy.deepcopy(base)
        for i, frame in enumerate(data):
            if kind == "gap" and i >= 5:
                frame["timestampMS"] += 300
            if kind == "missing" and i % 4 == 0:
                frame["hands"] = []
            if kind == "duplicate":
                frame["hands"] *= 2
            if kind == "spike" and i == 7:
                frame["hands"][0]["joints"][8]["x"] += 1
            if kind == "mirror":
                frame["mirrored"] = False
                frame["hands"][0]["handedness"] = "Left"
                for p in frame["hands"][0]["joints"]:
                    p["x"] = 1-p["x"]
            if kind == "aspect":
                frame["imageAspectRatio"] = 2
                for p in frame["hands"][0]["joints"]:
                    p["x"] /= 2
            if kind == "degenerate":
                frame["hands"][0]["joints"][9] = frame["hands"][0]["joints"][0].copy()
        windows.append(data)
    windows.extend(window for _, window in challenges([{"frames": base}]))
    if args.corpus:
        for sample in load_corpus(args.corpus)["samples"]:
            if sample["split"] not in ("calibration", "test"):
                continue
            windows.append(sample["frames"])
            for phase in (0, 83, 166):
                def record(window):
                    windows.append(copy.deepcopy(window))
                    return {"unknown": True, "candidates": []}
                replay_clip(sample["frames"], record, interval_ms=250, window_ms=1200, phase_ms=phase)
    root = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix="signloop-motion-local-") as directory:
        folder = Path(directory)
        fixture = folder/"fixture.json"
        fixture.write_text(json.dumps([query(w) for w in windows], allow_nan=False))
        binary = folder/"replay"
        subprocess.run(["swiftc", "-parse-as-library",
                        str(root/"ios/Signloop/Recognition.swift"),
                        str(root/"ios/Signloop/PretrainedSignPolicy.swift"),
                        str(root/"ios/Tests/MotionPolicyReplay.swift"), "-o", str(binary)], check=True)
        subprocess.run([str(binary), str(fixture)], check=True)


if __name__ == "__main__":
    main()
