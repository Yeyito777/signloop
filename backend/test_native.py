"""Offline Swift-client ↔ actual Python HTTP server contract test."""
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
import threading

from .server import make_server
from .service import Service
from .test_service import decision


class Gateway:
    def message(self, payload, provider):
        if provider == "typesafe":
            return decision()
        return {"model_name": "mock-cerebras", "content": json.dumps({
            "text": "Hello, thank you.", "raw_signs": ["HELLO", "THANK_YOU"],
        })}


def main():
    root = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix="signloop-native-") as directory:
        temp = Path(directory)
        token = secrets.token_urlsafe(32)
        server = make_server("127.0.0.1", 0, Service(Gateway()), token)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            sources = ["ios/Signloop/Recognition.swift", "ios/Signloop/BackendClient.swift",
                       "ios/Tests/BackendClientTests.swift"]
            subprocess.run(["swiftc", "-parse-as-library", *sources, "-o", str(temp / "native-tests")],
                           cwd=root, check=True)
            subprocess.run([str(temp / "native-tests")], check=True, env={
                **os.environ, "SIGNLOOP_TEST_URL": f"http://127.0.0.1:{server.server_port}",
                "SIGNLOOP_TEST_TOKEN": token,
            })
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    main()
