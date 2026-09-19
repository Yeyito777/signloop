"""Provision a local access token into the installed app, never the API key."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
from urllib.parse import urlparse

from .service import read_env


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--env-file", type=Path, default=Path(".env"))
    parser.add_argument("--device", default="Yeyito")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--url", help="Hosted HTTPS endpoint; omit for the local Mac backend.")
    args = parser.parse_args()
    config = read_env(args.env_file)
    token = config.get("SIGNLOOP_BACKEND_TOKEN", "")
    if len(token) < 24:
        raise SystemExit("Missing backend access token.")
    if args.url:
        parsed = urlparse(args.url)
        if (parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password
                or parsed.query or parsed.fragment or parsed.path not in ("", "/")):
            raise SystemExit("--url must be a bare HTTPS origin.")
        address = args.url.rstrip("/")
    else:
        hostname = subprocess.check_output(["scutil", "--get", "LocalHostName"], text=True).strip()
        address = f"http://{hostname}.local:{args.port}"
    with tempfile.TemporaryDirectory(prefix="signloop-pair-") as directory:
        path = Path(directory) / "backend-connection.json"
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as file:
            json.dump({"url": address, "token": token}, file)
        result = subprocess.run([
            "xcrun", "devicectl", "device", "copy", "to", "--device", args.device,
            "--source", str(path), "--destination", "Documents/backend-connection.json",
            "--domain-type", "appDataContainer", "--domain-identifier", "com.yeyito.signloop",
            "--timeout", "30",
        ], capture_output=True, text=True)
        if result.returncode:
            print((result.stdout + result.stderr).replace(token, "[REDACTED]"))
            raise SystemExit(result.returncode)
    print("Phone connection provisioned. No provider key was sent; app imports token into Keychain on next launch.")


if __name__ == "__main__":
    main()
