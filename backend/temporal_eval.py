"""Development comparison for the v2 matcher. No new downloads or provider calls."""
import argparse
from collections import Counter
import json
from pathlib import Path
import subprocess
from .basic_signs import LABELS


def summarize(rows):
    good = total = covered = 0
    accuracy_sum = 0.0
    by_label = {}
    unknown_guesses = 0
    for row in rows:
        predictions = [e["label"] for e in row["events"] if e.get("label")]
        if row["label"] not in LABELS:
            unknown_guesses += bool(predictions)
            continue
        total += 1
        covered += bool(predictions)
        top = Counter(predictions).most_common(1)[0][0] if predictions else None
        correct = top == row["label"]
        good += correct
        accuracy_sum += predictions.count(row["label"])/max(1, len(predictions))
        record = by_label.setdefault(row["label"], dict(total=0, majority_correct=0, with_guess=0))
        record["total"] += 1
        record["majority_correct"] += correct
        record["with_guess"] += bool(predictions)
    return dict(supported=total, with_guess=covered, majority_correct=good,
                mean_clip_window_correct=accuracy_sum/max(1, total),
                unsupported_with_guess=unknown_guesses, per_label=by_label,
                scheduled_events=sum(len(r["events"]) for r in rows),
                replay_ms=sum(r["elapsedMS"] for r in rows))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--replay", type=Path, required=True)
    p.add_argument("--bank", type=Path, required=True)
    p.add_argument("--validation", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    args = p.parse_args()
    if ".runtime" not in args.out.resolve().parts:
        p.error("Keep research reports private under .runtime")
    rows = json.loads(args.validation.read_text())
    if any(r["split"] != "val" for r in rows):
        p.error("Selection must use validation only")
    args.out.mkdir(parents=True, exist_ok=True)
    base = json.loads(args.bank.read_text())
    candidates = []
    for window in (1200, 1800, 2400):
        for weight in (0.0, 0.1, 0.2):
            bank = dict(base, version=2, windowMS=window, ruleWeight=weight)
            bank_path = args.out/f"bank-{window}-{weight}.json"
            raw_path = args.out/f"val-{window}-{weight}.json"
            bank_path.write_text(json.dumps(bank, separators=(",", ":")))
            subprocess.run([str(args.replay), str(bank_path), str(args.validation), str(raw_path)], check=True)
            report = summarize(json.loads(raw_path.read_text()))
            candidates.append(dict(window=window, weight=weight, report=report,
                                   bank=str(bank_path), raw=str(raw_path)))
    winner = max(candidates, key=lambda x: (x["report"]["majority_correct"],
        x["report"]["mean_clip_window_correct"], -x["window"], -x["weight"]))
    (args.out/"selection.json").write_text(json.dumps(dict(winner=winner, candidates=candidates), indent=2))
    (args.out/"basic-references.json").write_bytes(Path(winner["bank"]).read_bytes())
    print(json.dumps(winner, indent=2))


if __name__ == "__main__":
    main()
