"""Controlled vocabulary-size audit; never downloads or changes reference data."""
import argparse
import json
from pathlib import Path
import subprocess


def compare(narrow, wide, labels):
    """Require the exact same events and every original label's absolute score."""
    assert len(narrow) == len(wide), "Clip count changed"
    checked = switches = measured = 0
    for a, b in zip(narrow, wide):
        assert a["id"] == b["id"], "Clip order changed"
        assert len(a["events"]) == len(b["events"]), "Schedule changed"
        for x, y in zip(a["events"], b["events"]):
            assert x["timestamp"] == y["timestamp"], "Input timing changed"
            if x.get("scores") is None:
                assert y.get("scores") is None, "Availability changed"
                continue
            sa = {s["label"]: s.get("distance") for s in x["scores"]}
            sb = {s["label"]: s.get("distance") for s in y["scores"]}
            for label in labels:
                assert sa[label] == sb[label], f"Vocabulary-dependent score: {label}"
                checked += 1
            if x.get("label"):
                measured += 1
                switches += x["label"] != y.get("label")
    return dict(identical_original_scores=checked, measured_events=measured,
                winner_changes=switches)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--replay", type=Path, required=True)
    p.add_argument("--bank", type=Path, required=True)
    p.add_argument("--clips", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    args = p.parse_args()
    if ".runtime" not in args.out.resolve().parts:
        p.error("Keep research outputs private under .runtime")
    bank = json.loads(args.bank.read_text())
    assert len(bank["labels"]) == 32
    labels = bank["labels"][:16]
    subset = dict(bank, labels=labels,
                  references=[r for r in bank["references"] if r["label"] in labels])
    args.out.mkdir(parents=True, exist_ok=True)
    narrow_bank = args.out / "subset-bank.json"
    narrow_bank.write_text(json.dumps(subset))
    outputs = []
    for name, path in (("16", narrow_bank), ("32", args.bank)):
        output = args.out / f"scores-{name}.json"
        subprocess.run([str(args.replay.resolve()), str(path), str(args.clips),
                        str(output), "--scores"], check=True)
        outputs.append(json.loads(output.read_text()))
    result = compare(*outputs, labels)
    (args.out / "summary.json").write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
