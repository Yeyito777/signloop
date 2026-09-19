"""Causal ST-GCN rolling-window diagnostic on the frozen official-split plan.

No phone changes. Uses stored unmirrored Holistic observations, not recordings
uploaded to a provider. Simulated zero model delay; runtime timings reported
separately. Thresholds selected only on validation before test inference.
"""
import argparse
from collections import Counter
import json
from pathlib import Path
import statistics
import time

from .research_citizen import load_model, pose_tensor, rank, sha, SUPPORTED, accepted
from .research_data import LICENSE


def summarize(rows, score, margin):
    counts, labels = Counter(), {}
    for row in rows:
        truth = row["gloss"]
        supported = truth in SUPPORTED
        visible, pending, repeats = set(), None, 0
        raw_correct = False
        for event in row["events"]:
            label = None if not event["valid"] else accepted(event["ranked"], score, margin)
            raw_correct |= label == truth
            repeats = repeats+1 if label is not None and label == pending else 1
            pending = label
            if label is not None and repeats >= 2:
                visible.add(label)
        correct = truth in visible
        wrong = bool(visible-{truth})
        counts["clips"] += 1
        counts["supported" if supported else "unsupported"] += 1
        counts["supported_correct_visible"] += supported and correct
        counts["supported_raw_correct"] += supported and raw_correct
        counts["any_wrong_visible"] += wrong
        counts["unsupported_false_visible"] += not supported and bool(visible)
        if supported:
            entry = labels.setdefault(truth, Counter())
            entry["clips"] += 1
            entry["correct_visible"] += correct
            entry["raw_correct"] += raw_correct
            entry["wrong_visible"] += wrong
    return {"counts": counts, "labels": labels}


def calibrate(rows):
    best, chosen = None, None
    for score in (i*.025 for i in range(41)):
        for margin in (0, .025, .05, .1, .2, .3):
            c = summarize(rows, score, margin)["counts"]
            if c["any_wrong_visible"]:
                continue
            key = (c["supported_correct_visible"], score, margin)
            if best is None or key > best:
                best, chosen = key, (score, margin)
    assert chosen is not None
    return chosen


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--upstream", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--device", choices=("cpu", "mps"), default="cpu")
    parser.add_argument("--window-ms", type=int, choices=(1200, 2000, 3000), default=1200)
    parser.add_argument("--validation-only", action="store_true")
    parser.add_argument("--accept-research-license", action="store_true")
    args = parser.parse_args()
    if not args.accept_research_license or ".runtime" not in args.out.parts:
        parser.error(f"Read {LICENSE}; acknowledge research terms and use ignored output.")
    import numpy as np
    import torch
    torch.set_num_threads(4)
    plan_path = args.out/"plan.json"
    plan = json.loads(plan_path.read_text())
    samples = [s for s in plan["samples"] if not args.validation_only or s["split"] == "val"]
    stem = f"stgcn-stream-{args.window_ms}" + ("-val" if args.validation_only else "")
    model = load_model("stgcn", args.upstream, args.checkpoint)
    if args.device == "mps":
        model = model.float().to("mps")
    rows, parameters, durations = [], None, []
    for index, sample in enumerate(samples):
        if sample["split"] == "test" and parameters is None:
            parameters = calibrate(rows)
            (args.out/(stem+"-calibration.json")).write_text(json.dumps({
                "parameters": parameters, "summary": summarize(rows, *parameters)}, indent=2))
            print("FROZEN STREAM score/margin", parameters, flush=True)
        with np.load(args.out/"poses"/(sample["id"]+".npz"), allow_pickle=False) as stored:
            if str(stored["video_sha256"]) != sample["video_sha256"]:
                raise ValueError("Mismatched pose cache.")
            data, fps = stored["data"], float(stored["fps"])
        events, previous = [], -10000.
        for end in range(5, len(data)):
            now = end/fps*1000
            if now-previous < 250:
                continue
            previous = now
            start = max(0, int(np.ceil(end-args.window_ms/1000*fps)))
            window = data[start:end+1]
            # Current hand missing = unknown, never classify a stale body alone.
            valid = bool(np.any(window[-1, 33:]) and np.any(window[-1, [11, 12]]))
            if valid:
                began = time.perf_counter()
                value = pose_tensor(window)
                with torch.inference_mode():
                    tensor = torch.from_numpy(value)[None]
                    if args.device == "mps":
                        tensor = tensor.float().to("mps")
                    logits = model(tensor)[0].cpu().numpy()
                durations.append((time.perf_counter()-began)*1000)
                ranked = rank(logits, plan["vocabulary"])
            else:
                ranked = []
            events.append({"t_ms": now, "valid": valid, "ranked": ranked})
        rows.append({k: sample[k] for k in ("id", "split", "gloss", "signer")} | {"events": events})
        print(f"stream {index+1}/{len(samples)}", flush=True)
    if parameters is None:
        parameters = calibrate(rows)
    report = {"complete": True, "plan_sha256": sha(plan_path), "parameters": parameters,
              "device": args.device, "precision": "float32" if args.device == "mps" else "float64",
              "window_ms": args.window_ms, "minimum_interval_ms": 250, "confirmation_results": 2,
              "scope": "Causal observed windows, zero simulated compute delay; not phone UI replay.",
              "model_median_ms": statistics.median(durations),
              "model_p95_ms": sorted(durations)[int(.95*(len(durations)-1))],
              "splits": {s: summarize([r for r in rows if r["split"] == s], *parameters)
                         for s in (("val",) if args.validation_only else ("val", "test"))}, "rows": rows}
    (args.out/(stem+"-report.json")).write_text(json.dumps(report, indent=2))
    print(json.dumps({k: v for k, v in report.items() if k != "rows"}, indent=2))


if __name__ == "__main__":
    main()
