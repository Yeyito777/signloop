"""Local development server. TLS reverse proxy required for public deployment."""
from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hmac
import json
from pathlib import Path
import threading

from .service import Backboard, References, Service, ServiceError, VOCABULARY, read_env, validate_frames

MAX_BODY = 300_000


def make_server(host: str, port: int, service: Service, token: str) -> ThreadingHTTPServer:
    if len(token) < 24:
        raise ServiceError("config", "Set a random SIGNLOOP_BACKEND_TOKEN of at least 24 characters.", 503)
    slots = threading.BoundedSemaphore(2)

    class Handler(BaseHTTPRequestHandler):
        def setup(self):
            super().setup()
            self.connection.settimeout(45)

        def log_message(self, *args):
            pass  # No camera data, captions, request paths or credentials in logs.

        def send_json(self, status: int, payload: dict):
            data = json.dumps(payload, allow_nan=False).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            self.wfile.write(data)

        def authorize(self):
            if not hmac.compare_digest(self.headers.get("Authorization", ""), "Bearer " + token):
                raise ServiceError("unauthorized", "Invalid backend access token.", 401)

        def body(self):
            if self.headers.get("Transfer-Encoding"):
                raise ServiceError("body", "Chunked requests are not supported.", 400)
            try:
                size = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                raise ServiceError("body", "Invalid request size.", 400) from None
            if not 0 < size <= MAX_BODY:
                raise ServiceError("body", "Request body must be 1–300000 bytes.", 413)
            if self.headers.get_content_type() != "application/json":
                raise ServiceError("body", "Use application/json.", 415)
            try:
                raw = self.rfile.read(size)
                if len(raw) != size:
                    raise ValueError()
                value = json.loads(raw, parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
                if not isinstance(value, dict):
                    raise ValueError()
                return value
            except (ValueError, UnicodeError):
                raise ServiceError("body", "Invalid JSON object.", 400) from None

        def dispatch(self):
            if self.command == "GET" and self.path == "/health":
                return {"status": "ok", "experimental": True, "classifier": "typesafe/jev-latest",
                        "caption_provider": "cerebras", "caption_model": service.caption_model}
            self.authorize()
            if self.command == "GET" and self.path == "/v1/references":
                return {"labels": sorted(service.references.snapshot()), "vocabulary": list(VOCABULARY),
                        "validated": False}
            if self.command == "DELETE" and self.path == "/v1/references":
                service.references.delete_all()
                return {"deleted": True}
            if self.command == "POST":
                body = self.body()
                if self.path == "/v1/classify":
                    return service.classify(validate_frames(body.get("frames")))
                if self.path == "/v1/caption":
                    return service.caption(body.get("raw_signs"))
                if self.path == "/v1/references":
                    service.references.save(body.get("label"), validate_frames(body.get("frames")),
                                            body.get("human_confirmed"))
                    return {"labels": sorted(service.references.snapshot()), "saved": True, "validated": False}
            raise ServiceError("not_found", "Unknown endpoint.", 404)

        def handle_request(self):
            if not slots.acquire(blocking=False):
                self.send_json(429, {"error": "busy", "message": "Backend is busy. Try again shortly."})
                return
            try:
                self.send_json(200, self.dispatch())
            except ServiceError as error:
                self.send_json(error.status, {"error": error.code, "message": error.message})
            except (BrokenPipeError, ConnectionResetError, TimeoutError):
                pass
            except Exception:
                # Never leak a traceback containing a request or credential.
                self.send_json(500, {"error": "internal", "message": "Backend request failed."})
            finally:
                slots.release()

        do_GET = handle_request
        do_POST = handle_request
        do_DELETE = handle_request

    server = ThreadingHTTPServer((host, port), Handler)
    server.daemon_threads = True
    return server


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--env-file", type=Path, default=Path(".env"))
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--data-dir", type=Path, default=Path(".runtime/backend"))
    args = parser.parse_args()
    values = read_env(args.env_file)
    service = Service(Backboard(values.get("BACKBOARD_API_KEY", "")),
                      References(args.data_dir / "references.json"),
                      values.get("CEREBRAS_MODEL", "openai/gpt-oss-120b"))
    server = make_server(args.host, args.port, service, values.get("SIGNLOOP_BACKEND_TOKEN", ""))
    print(f"Signloop backend: http://{args.host}:{args.port} (experimental; no payload logging)", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
