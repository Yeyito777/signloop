"""First-party corpus builder. The only data path that can produce a shippable model.

Recordings come from the app's landmark export (CameraTracker.exportLandmarks -> honk-and-tell-landmarks.json):
hand landmarks only, no pixels. Each clip is added with explicit provenance and consent so that
recognition.data.assert_shippable can prove what a model was trained on.

    python -m recognition.collect add --corpus corpus.json --export honk-and-tell-landmarks.json \\
        --label HELLO --signer P07 --session 2026-09-19-a --device "iPhone 15" \\
        --consent "Written consent v1, signed 2026-09-19, landmarks only, redistribution allowed" \\
        --lighting bright --distance arm --background plain --speed normal
    python -m recognition.collect report --corpus corpus.json

Rules enforced here (not left to convention):
  * --consent is mandatory and stored per clip; a clip without it cannot be added.
  * signer is a pseudonymous ID chosen by the collector; sessions are per signer.
  * labels come from a fluent signer's verification (--verified-by), else the clip is marked unverified
    and excluded from evaluation by report/data checks.
  * the hard-test coverage report lists exactly which conditions still have no held-out signer.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path
import sys

from . import data as D

CONDITIONS = {
    "lighting": ["bright", "dim", "mixed"],
    "distance": ["close", "arm", "far"],
    "background": ["plain", "busy"],
    "speed": ["slow", "normal", "fast"],
    "occlusion": ["none", "partial"],
    "handedness": ["Right", "Left"],
}
NEGATIVE_KINDS = ["rest", "random_motion", "transition", "unsupported_shape", "incomplete", "incorrect", "nonsign"]


def load_or_new(path: Path, name: str) -> dict:
    if path.exists():
        return D.load_corpus(path)
    return {"version": 1, "dataset": name, "samples": []}


def add(args) -> dict:
    export = json.loads(Path(args.export).read_text())
    frames = export["frames"]
    if len(frames) < 6 or len(frames) > 90:
        raise SystemExit("export must hold 6..90 frames (one attempted sign)")
    corpus = load_or_new(Path(args.corpus), args.dataset)
    n = sum(1 for s in corpus["samples"] if s["signer"] == args.signer)
    sample = {
        "id": f"{args.signer}-{args.session}-{args.label}-{n:03d}", "label": args.label, "signer": args.signer,
        "session": f"{args.signer}-{args.session}", "source": "first-party consented recording (Honk & Tell app landmark export)",
        "license": args.consent, "redistribution": "ALLOWED" if args.allow_redistribution else "PROHIBITED",
        "kind": args.kind or ("sign" if args.label != D.UNKNOWN else "nonsign"),
        "device": args.device, "fps": _fps(frames), "duration_ms": frames[-1]["timestampMS"] - frames[0]["timestampMS"],
        "verified_by": args.verified_by or "", "frames": frames,
    }
    for key in CONDITIONS:
        if getattr(args, key, None):
            sample[key] = getattr(args, key)
    if args.skin_tone_self_reported:
        sample["skin_tone_self_reported"] = args.skin_tone_self_reported
    corpus["samples"].append(sample)
    D.validate_corpus(corpus)
    Path(args.corpus).write_text(json.dumps(corpus))
    return sample


def _fps(frames):
    dt = (frames[-1]["timestampMS"] - frames[0]["timestampMS"]) / max(len(frames) - 1, 1)
    return round(1000 / dt, 1) if dt > 0 else 0


def report(corpus_path: str) -> str:
    corpus = D.load_corpus(corpus_path)
    s = corpus["samples"]
    signers = sorted({x["signer"] for x in s})
    lines = [f"samples: {len(s)}   signers: {len(signers)}"]
    per_label = Counter(x["label"] for x in s)
    lines.append("per label: " + ", ".join(f"{k}={v}" for k, v in sorted(per_label.items())))
    unverified = sum(1 for x in s if x["label"] != D.UNKNOWN and not x.get("verified_by"))
    lines.append(f"labels not verified by a fluent signer: {unverified}  (exclude from evaluation until verified)")
    lines.append(f"clips not cleared for redistribution: {sum(1 for x in s if x['redistribution'] != 'ALLOWED')}  "
                 "(any of these in training makes a model non-shippable)")
    lines.append("negatives by kind: " + ", ".join(f"{k}={sum(1 for x in s if x['label'] == D.UNKNOWN and x.get('kind') == k)}"
                                                 for k in NEGATIVE_KINDS))
    lines.append("")
    lines.append("Hard-test coverage (signers per condition; each needs >= 1 signer NOT used in training):")
    for cond, values in CONDITIONS.items():
        by = defaultdict(set)
        for x in s:
            if x.get(cond):
                by[x[cond]].add(x["signer"])
        lines.append(f"  {cond:11s} " + "  ".join(f"{v}={len(by.get(v, ()))}" for v in values))
    tones = Counter(x.get("skin_tone_self_reported") for x in s if x.get("skin_tone_self_reported"))
    lines.append(f"  skin tone (optional, self-reported) signers by group: {dict(tones) or 'none recorded'}")
    if len(signers) < 10:
        lines.append(f"\nNOTE: {len(signers)} signers. Signer-independent claims need many more; with < ~73 validation "
                     "negatives the rejection policy will refuse to show any sign (by design).")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("add")
    a.add_argument("--corpus", required=True)
    a.add_argument("--export", required=True)
    a.add_argument("--label", required=True, help="supported label, or UNKNOWN for negatives")
    a.add_argument("--signer", required=True)
    a.add_argument("--session", required=True)
    a.add_argument("--device", required=True)
    a.add_argument("--consent", required=True, help="consent record text/reference; mandatory")
    a.add_argument("--allow-redistribution", action="store_true", help="consent covers bundling a model trained on this clip")
    a.add_argument("--verified-by", help="ID of the fluent signer who confirmed the label")
    a.add_argument("--kind", choices=NEGATIVE_KINDS + ["sign"])
    a.add_argument("--dataset", default="Honk & Tell first-party consented recordings")
    a.add_argument("--skin-tone-self-reported", help="optional, self-reported by the signer")
    for c, vals in CONDITIONS.items():
        a.add_argument(f"--{c}", choices=vals)
    r = sub.add_parser("report")
    r.add_argument("--corpus", required=True)
    args = ap.parse_args()
    if args.cmd == "add":
        s = add(args)
        print("added", s["id"], f"({len(s['frames'])} frames, {s['fps']} fps)")
    else:
        print(report(args.corpus))


if __name__ == "__main__":
    main()
