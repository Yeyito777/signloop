"""Private WE amplitude experiment. Train-signer folds + validation only."""
import argparse
import copy
import json
from pathlib import Path
import subprocess
from collections import Counter

LABELS = ["HELLO", "MY", "NAME", "TODAY", "WE", "SHOW", "PHONE",
          "PLEASE", "SORRY", "THANKYOU", "ILOVEYOU"]


def smaller_motion(clip, scale=0.65):
    """Synthetic stress input derived from a real clip; never new ground truth."""
    result = copy.deepcopy(clip)
    means = {}
    for side in ("Left", "Right"):
        hands = [h for f in clip["frames"] for h in f["hands"] if h.get("poseSide") == side]
        wrists = [next(p for p in h["points"] if p["id"] == 0) for h in hands]
        if wrists:
            means[side] = {axis: sum(p[axis] for p in wrists)/len(wrists) for axis in ("x", "y")}
    pose_means = {}
    for joint in (13, 14, 15, 16):
        points = [p for f in clip["frames"] for p in f["pose"] if p["id"] == joint]
        if points:
            pose_means[joint] = {axis: sum(p[axis] for p in points)/len(points) for axis in ("x", "y")}
    for frame in result["frames"]:
        for hand in frame["hands"]:
            center = means.get(hand.get("poseSide"))
            if center:
                wrist = next(p for p in hand["points"] if p["id"] == 0)
                delta = {axis: (scale-1)*(wrist[axis]-center[axis]) for axis in ("x", "y")}
                for point in hand["points"]:
                    for axis in ("x", "y"):
                        point[axis] += delta[axis]
        for point in frame["pose"]:
            center = pose_means.get(point["id"])
            if center:
                for axis in ("x", "y"):
                    point[axis] = center[axis]+scale*(point[axis]-center[axis])
    return result


def stats(rows):
    correct = supported = we_windows = false_we = 0
    wrong_ids, false_we_ids = [], []
    for row in rows:
        predictions = [e["label"] for e in row["events"] if e.get("label")]
        winner = Counter(predictions).most_common(1)
        if row["label"] in LABELS:
            supported += 1
            correct += bool(winner and winner[0][0] == row["label"])
            if not winner or winner[0][0] != row["label"]:
                wrong_ids.append(row["id"])
        if row["label"] == "WE":
            we_windows += predictions.count("WE")
        elif "WE" in predictions:
            false_we += 1
            false_we_ids.append(row["id"])
    return dict(correct=correct, supported=supported, we_windows=we_windows,
                false_we_clips=false_we, wrong_ids=wrong_ids, false_we_ids=false_we_ids)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--replay", type=Path, required=True)
    p.add_argument("--bank", type=Path, required=True)
    p.add_argument("--raw-bank", type=Path, required=True)
    p.add_argument("--validation", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    a = p.parse_args()
    assert ".runtime" in a.out.resolve().parts
    a.out.mkdir(parents=True, exist_ok=True)
    bank = json.loads(a.bank.read_text())
    raw = json.loads(a.raw_bank.read_text())
    val = json.loads(a.validation.read_text())
    assert val and all(r["split"] == "val" for r in val)
    assert all(r["split"] == "train" for r in bank["references"]+raw["references"])
    source_ids = {r["id"] for r in bank["references"]}
    we = [r for r in raw["references"] if r["label"] == "WE" and r["id"] in source_ids]
    def run(bank_path, clips, name, scale):
        output = a.out/f"{name}-{scale}.json"
        command = [str(a.replay.resolve()), str(bank_path), str(clips), str(output), "--presentation"]
        if scale != 1:
            command.append(f"--we-scale={scale}")
        subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
        return json.loads(output.read_text())
    reports = []
    for scale in (1, 0.65, 0.8):
        natural, stress = [], []
        for i, clip in enumerate(we):
            fold = dict(bank, references=[r for r in bank["references"] if r["signer"] != clip["signer"]])
            fold_path = a.out/f"fold-{i}.json"
            fold_path.write_text(json.dumps(fold))
            for mode, query in (("natural", clip), ("stress", smaller_motion(clip))):
                query_path = a.out/f"query-{i}-{mode}.json"
                query_path.write_text(json.dumps([query]))
                rows = run(fold_path, query_path, f"{mode}-{i}", scale)
                (natural if mode == "natural" else stress).extend(rows)
        validation = run(a.bank, a.validation, "validation", scale)
        report = dict(scale=scale, natural=stats(natural), stress=stats(stress),
                      validation=stats(validation))
        reports.append(report)
        print(json.dumps(report), flush=True)
    (a.out/"summary.json").write_text(json.dumps(reports, indent=2))


if __name__ == "__main__":
    main()
