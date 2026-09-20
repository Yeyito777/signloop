"""Local development server. TLS reverse proxy required for public deployment."""
from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hmac
import hashlib
import json
from pathlib import Path
import threading

from .service import Backboard, Service, ServiceError, VOCABULARY, read_env, validate_frames
from .voice import ElevenLabsVoice, validate_speech_input

MAX_BODY = 300_000


def make_server(host: str, port: int, service: Service | None, token: str,
                speech: ElevenLabsVoice | None = None) -> ThreadingHTTPServer:
    """Build the local API server.

    ``speech`` is deliberately optional so existing classification-only callers
    retain their previous behavior.  Passing ``service=None`` supports the
    narrowly-scoped voice-only deployment mode.
    """
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
                return {"status": "ok", "experimental": True,
                        "classifier": getattr(service, "mode", "unavailable"),
                        "caption_provider": "cerebras" if service and service.caption_model else None,
                        "caption_model": service.caption_model if service else None,
                        "speech": "elevenlabs" if speech else None}
            self.authorize()
            if self.command == "GET" and self.path == "/v1/status":
                return {"status": "ok",
                        "vocabulary": getattr(service, "vocabulary", list(VOCABULARY)) if service else [],
                        "mode": getattr(service, "mode", "unavailable"), "validated": False,
                        "classifier": bool(service), "caption": bool(service), "speech": bool(speech)}
            if self.command == "POST":
                # Check feature availability before consuming an unavailable
                # endpoint's payload, but only after the shared token check.
                if self.path in ("/v1/classify", "/v1/caption") and not service:
                    raise ServiceError("unavailable", "This feature is not configured.", 503)
                if self.path == "/v1/speech" and not speech:
                    raise ServiceError("speech_unavailable", "Speech is not configured.", 503)
                body = self.body()
                if self.path == "/v1/classify":
                    return service.classify(validate_frames(body.get("frames")))
                if self.path == "/v1/caption":
                    return service.caption(body.get("raw_signs"))
                if self.path == "/v1/speech":
                    text, emotion = validate_speech_input(body.get("text"), body.get("emotion", "joy"))
                    return speech.speak(text, emotion)
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


def reference_service(corpus_path: Path, report_path: Path, host: str):
    from .matcher import load_corpus, MATCHERS, ReferenceService
    corpus = load_corpus(corpus_path)
    if corpus.get("redistribution") == "PROHIBITED" and host not in ("localhost", "127.0.0.1", "::1"):
        raise ValueError("Restricted research corpus may only be evaluated on loopback.")
    report = json.loads(report_path.read_text())
    if report.get("protocol") == "rolling-calibration-v1":
        raise ValueError("Rolling calibration requires its tested client cadence/filter; "
                         "these experimental reports cannot configure the legacy live server.")
    digest = hashlib.sha256(corpus_path.read_bytes()).hexdigest()
    if report.get("corpus_sha256") != digest or report.get("model") not in MATCHERS:
        raise ValueError("Calibration report does not match this corpus/model.")
    params = report["parameters"]
    matcher = MATCHERS[report["model"]](corpus["samples"], **params)
    if not set(matcher.labels) <= set(VOCABULARY):
        raise ValueError("Corpus labels must be in the current app vocabulary.")
    return ReferenceService(matcher)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--env-file", type=Path, default=Path(".env"))
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--reference-corpus", type=Path)
    parser.add_argument("--calibration-report", type=Path)
    parser.add_argument("--voice-only", action="store_true",
                        help="Serve only authenticated ElevenLabs speech; no Backboard key is needed.")
    args = parser.parse_args()
    values = read_env(args.env_file)
    if bool(args.reference_corpus) != bool(args.calibration_report):
        parser.error("--reference-corpus and --calibration-report must be supplied together.")
    if args.voice_only and args.reference_corpus:
        parser.error("--voice-only cannot be combined with a reference classifier.")
    if args.voice_only:
        service = None
    elif args.reference_corpus:
        service = reference_service(args.reference_corpus, args.calibration_report, args.host)
    else:
        service = Service(Backboard(values.get("BACKBOARD_API_KEY", ""), timeout=8),
                          caption_model=values.get("CEREBRAS_MODEL", "openai/gpt-oss-120b"))
    api_key, voice_id = values.get("ELEVENLABS_API_KEY", ""), values.get("ELEVENLABS_VOICE_ID", "")
    # An absent or partial optional speech configuration remains unavailable at
    # the endpoint rather than preventing the rest of the backend from starting.
    speech = ElevenLabsVoice(api_key, voice_id) if api_key and voice_id else None
    server = make_server(args.host, args.port, service, values.get("SIGNLOOP_BACKEND_TOKEN", ""), speech)
    print(f"Honk & Tell backend: http://{args.host}:{args.port} (experimental; no payload logging)", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
