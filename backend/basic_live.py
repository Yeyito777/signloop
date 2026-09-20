"""Private offline research export/calibration. Never embeds data in an app."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import subprocess
from .basic_corpus import samples
from .basic_signs import LABELS, DEMO_LABELS, PRESENTATION_LABELS


def frames(a):
    def point(i, xyz):
        return dict(id=int(i), x=float(xyz[0]), y=float(xyz[1]), z=float(xyz[2]))
    result = []
    for t, timestamp in enumerate(a["timestamp_ms"]):
        hands = []
        for slot in range(2):
            if a["hand_valid"][t, slot]:
                side = int(a["hand_sides"][t, slot])
                hands.append(dict(points=[point(i, xyz) for i, xyz in enumerate(a["hands"][t, slot])],
                                  modelHandedness="Unknown", handednessScore=0,
                                  poseSide={0: "Left", 1: "Right"}.get(side)))
        result.append(dict(schemaVersion=1, timestampMS=int(timestamp),
            width=int(a["width"]), height=int(a["height"]), camera="research",
            coordinateSpace="unmirrored image", hands=hands,
            pose=[point(i, xyz) for i, xyz in enumerate(a["pose"][t]) if a["pose_valid"][t, i]],
            face=[point(i, xyz) for i, xyz in zip(a["face_ids"], a["face_anchors"][t])]
                 if a["face_valid"][t] else [],
            expressions={str(k): float(v) for k, v in zip(a["blendshape_names"], a["blendshapes"][t])},
            timingsMS={}))
    return result


def export(folder, out):
    out.mkdir(parents=True, exist_ok=True)
    records = [dict(id=r["id"], label=r["label"], split=r["split"], signer=r["signer"],
                    frames=frames(a)) for r, a in samples(folder)]
    vocabulary = json.loads((Path(folder)/"plan.json").read_text())["labels"]
    if vocabulary not in (list(LABELS), list(DEMO_LABELS), list(PRESENTATION_LABELS)):
        raise ValueError("Unsupported vocabulary")
    bank = dict(version=2, labels=vocabulary, maxDistance=0.0, minMargin=1.0,
                references=[r for r in records if r["split"] == "train"])
    (out/"basic-references.json").write_text(json.dumps(bank, separators=(",", ":"), allow_nan=False))
    for split in ("val", "test"):
        (out/f"{split}.json").write_text(json.dumps([r for r in records if r["split"] == split],
                                                   separators=(",", ":"), allow_nan=False))


def accepted_events(row, distance, margin):
    pending, count, displayed = None, 0, set()
    for event in row["events"]:
        label = event.get("label")
        if event["distance"] > distance or event["margin"] < margin:
            label = None
        if label is None:
            pending, count = None, 0
        else:
            count = count + 1 if pending == label else 1
            pending = label
            if count >= 2:
                displayed.add(label)
    return displayed


def metrics(rows, distance, margin, labels=LABELS):
    good = wrong = false = supported = unknown = 0
    per_label = {}
    for row in rows:
        shown = accepted_events(row, distance, margin)
        if row["label"] in labels:
            supported += 1
            good += row["label"] in shown
            wrong += bool(shown - {row["label"]})
            p = per_label.setdefault(row["label"], dict(total=0, correct=0, wrong=0))
            p["total"] += 1
            p["correct"] += row["label"] in shown
            p["wrong"] += bool(shown - {row["label"]})
        else:
            unknown += 1
            false += bool(shown)
    return dict(supported=supported, correct=good, wrong=wrong, unsupported=unknown,
                false_display=false, per_label=per_label)


def calibrate(raw, bank):
    rows = json.loads(raw.read_text())
    if not rows or any(r["split"] != "val" for r in rows):
        raise ValueError("Only validation may select rejection thresholds")
    b = json.loads(bank.read_text())
    options = []
    for distance in (0.08, .12, .18, .25, .35, .5, .7, 1.0):
        for margin in (0.02, .05, .10, .15, .20, .30):
            m = metrics(rows, distance, margin, b["labels"])
            # Small validation cohort: zero unsupported displays and at most
            # one wrong supported clip. Fail closed if no useful policy exists.
            if m["false_display"] == 0 and m["wrong"] <= 1:
                options.append((m["correct"], -m["wrong"], -distance, margin, m))
    winner = max(options, key=lambda x: x[:4]) if options else (0, 0, 0, 1, {})
    b["maxDistance"], b["minMargin"] = -winner[2], winner[3]
    bank.write_text(json.dumps(b, separators=(",", ":"), allow_nan=False))
    report = dict(maxDistance=b["maxDistance"], minMargin=b["minMargin"],
                  validation=winner[4], scope="Development replay, not live accuracy")
    (bank.parent/"calibration.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))


def validate_deployment(bank_path, corpus):
    b = json.loads(bank_path.read_text())
    plan_path = corpus/"plan.json"
    plan = json.loads(plan_path.read_text())
    report = json.loads((corpus/"report.json").read_text())
    if not report["complete"] or report["plan_sha256"] != hashlib.sha256(plan_path.read_bytes()).hexdigest():
        raise ValueError("Incomplete/unbound source corpus")
    training = {r["id"]: r for r in plan["samples"] if r["split"] == "train"}
    labels = plan.get("labels", list(LABELS))
    if (b["version"] != 2 or labels not in (list(LABELS), list(DEMO_LABELS), list(PRESENTATION_LABELS))
            or b["labels"] != labels or not 1 <= len(b["references"]) <= 256):
        raise ValueError("Unexpected reference schema/vocabulary")
    if len({r["id"] for r in b["references"]}) != len(b["references"]):
        raise ValueError("Duplicate references")
    for row in b["references"]:
        source = training.get(row["id"])
        if source is None or any(row[k] != source[k] for k in ("label", "split", "signer")):
            raise ValueError("Only original training references may reach the phone")
        if row["frames"] or len(row["features"]) != 16:
            raise ValueError("Use the compact --pack asset, not raw frames")
    if not math.isfinite(b["maxDistance"]) or not 0 <= b["maxDistance"] <= 1:
        raise ValueError("No useful calibrated rejection policy")
    if not math.isfinite(b["minMargin"]) or not 0 <= b["minMargin"] <= 1:
        raise ValueError("Invalid rejection margin")
    return b


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("action", choices=["export", "calibrate", "report", "provision"])
    p.add_argument("--corpus", type=Path)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--raw", type=Path)
    p.add_argument("--device")
    p.add_argument("--bundle-id", choices=["com.yeyito.signloop", "com.signloop.mobile"], default="com.yeyito.signloop")
    p.add_argument("--accept-research-license", action="store_true")
    args = p.parse_args()
    if ".runtime" not in args.out.resolve().parts:
        p.error("Research assets must stay under ignored .runtime")
    bank = args.out/"basic-references.json"
    if args.action == "export":
        export(args.corpus, args.out)
    elif args.action == "calibrate":
        calibrate(args.raw, bank)
    elif args.action == "report":
        b = json.loads(bank.read_text())
        print(json.dumps(metrics(json.loads(args.raw.read_text()), b["maxDistance"],
                                 b["minMargin"], b["labels"]), indent=2))
    else:
        if not args.device or not args.corpus or not args.accept_research_license:
            p.error("Private research provisioning requires --device, --corpus and --accept-research-license")
        packed = args.out/"basic-references-packed.json"
        b = validate_deployment(packed, args.corpus)
        subprocess.run(["xcrun", "devicectl", "device", "copy", "to", "--device", args.device,
            "--domain-type", "appDataContainer", "--domain-identifier", args.bundle_id,
            "--source", str(packed), "--destination", "Documents/basic-references.json", "--timeout", "60"],
            check=True)
        print(f"Provisioned {len(b['references'])} private training references; no app bundle or server involved.")


if __name__ == "__main__":
    main()
