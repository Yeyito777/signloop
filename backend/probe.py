"""Opt-in live API test. Synthetic input only; this does not validate ASL."""
import argparse
import json
from pathlib import Path
import tempfile
import time

from .service import Backboard, References, Service, ServiceError, read_env, parse_decision


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--env-file", type=Path, default=Path(".env"))
    args = parser.parse_args()
    config = read_env(args.env_file)
    gateway = Backboard(config.get("BACKBOARD_API_KEY", ""))
    providers = gateway.request("/models/providers")["providers"]
    if not {"typesafe", "cerebras"} <= set(providers):
        raise ServiceError("catalog", "Required providers missing.")
    start = time.monotonic()
    decision = gateway.message({
        "content": "Synthetic connection test: no hand observations exist.",
        "model_name": "jev-latest",
        "system_one": {"state": {"frames": []}, "questions": {"sign": {
            "type": "choice", "instructions": "Choose UNKNOWN when no hand observations exist.",
            "criteria": {"HELLO": "A validated hello gesture is observed.", "UNKNOWN": "No usable hand observations."},
        }}},
    }, "typesafe")
    parsed = parse_decision(decision, {"HELLO"})
    assert parsed["unknown"], "Empty synthetic input should be rejected."
    print(json.dumps({"test": "jev_empty_synthetic_input", "passed": True,
                      "model": parsed["model"], "seconds": round(time.monotonic() - start, 2)}))
    with tempfile.TemporaryDirectory() as temp:
        service = Service(gateway, References(Path(temp) / "references.json"),
                          config.get("CEREBRAS_MODEL", "openai/gpt-oss-120b"))
        start = time.monotonic()
        caption = service.caption(["HELLO", "THANK_YOU"])
        assert caption["polished"], "Caption must pass the meaning guard."
        print(json.dumps({"test": "cerebras_synthetic_labels", "passed": True,
                          "seconds": round(time.monotonic() - start, 2), **caption}))
    print("Connectivity only. Real landmark sign recognition remains unvalidated.")


if __name__ == "__main__":
    try:
        main()
    except ServiceError as error:
        raise SystemExit(f"{error.code}: {error.message}")
