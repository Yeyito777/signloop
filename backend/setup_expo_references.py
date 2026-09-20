"""Each researcher builds their own private bank. Never redistributes source data."""
import argparse
import fcntl
import json
from pathlib import Path
import subprocess
import sys
from .basic_live import export, validate_deployment
from .research_data import LICENSE

ROOT = Path(__file__).resolve().parent.parent
# Published development parameters, NOT learned reference coordinates.
POLICY = dict(windowMS=1200, ruleWeight=0, queryFrames=4, maxDistance=0, minMargin=1)


def prepare(corpus, output):
    if ".runtime" not in output.resolve().parts or ".runtime" not in corpus.resolve().parts:
        raise ValueError("All private data must remain inside ignored .runtime")
    export(corpus, output)
    source = output/"basic-references.json"
    bank = json.loads(source.read_text())
    bank.update(POLICY)
    source.write_text(json.dumps(bank, separators=(",", ":"), allow_nan=False))
    replay = output/"pack-references"
    subprocess.run(["swiftc", "-O", "-parse-as-library", str(ROOT/"ios/Signloop/Skeleton.swift"),
                    str(ROOT/"ios/Signloop/BasicSignMatcher.swift"), str(ROOT/"ios/Tests/BasicSignReplay.swift"),
                    "-o", str(replay)], check=True)
    packed = output/"basic-references-packed.json"
    subprocess.run([str(replay), str(source), "--pack", str(packed)], check=True)
    result = validate_deployment(packed, corpus)
    print(f"READY: {len(result['references'])} training references, {packed.stat().st_size/1e6:.2f} MB at {packed}")
    print("Research-only local file. DO NOT commit, bundle publicly, or send it to teammates/providers.")
    return packed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--accept-research-license", action="store_true")
    parser.add_argument("--device", help="Optional iPhone ID: install Expo first; provision com.signloop.mobile")
    parser.add_argument("--existing-corpus", type=Path, help="Reuse your OWN complete local corpus; never a teammate's copy")
    parser.add_argument("--plan-only", action="store_true", help="Inspect selected source sizes without downloading videos")
    args = parser.parse_args()
    if not args.accept_research_license:
        parser.error(f"Read {LICENSE}; explicit --accept-research-license is required.")
    corpus = args.existing_corpus.resolve() if args.existing_corpus else ROOT/".runtime/presentation-signs-v1"
    output = ROOT/".runtime/expo-references"
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Extraction/packing share an output directory. Refuse a second invocation
    # instead of mixing banks from different corpora or provisioning mid-write.
    lock = (output/".setup.lock").open("a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        lock.close()
        parser.error("Another reference setup is running; wait for it to finish.")
    try:
        run(args, corpus, output)
    finally:
        lock.close()


def run(args, corpus, output):
    if not args.existing_corpus:
        subprocess.run([sys.executable, "-m", "backend.basic_signs", "plan" if args.plan_only else "extract",
                        "--vocabulary", "presentation11", "--out", str(corpus),
                        "--models", str(ROOT/"ios/Signloop/Resources"), "--accept-research-license"], cwd=ROOT, check=True)
    if args.plan_only:
        return
    prepare(corpus, output)
    if args.device:
        subprocess.run([sys.executable, "-m", "backend.basic_live", "provision", "--out", str(output),
                        "--corpus", str(corpus), "--bundle-id", "com.signloop.mobile", "--device", args.device,
                        "--accept-research-license"], cwd=ROOT, check=True)
    else:
        print("Install Expo, then rerun this command with --device YOUR_IPHONE_ID to provision it.")


if __name__ == "__main__":
    main()
