"""Mocked tests for the server-side ElevenLabs proxy; no provider calls are made."""
import base64
from email.message import Message
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import http.client
import json
import threading
import unittest
import urllib.error
import urllib.request
from unittest import mock

from .server import make_server
from .service import ServiceError
from .voice import (
    ELEVENLABS_URL, MAX_AUDIO_BASE64_CHARACTERS, MAX_UPSTREAM_RESPONSE_BYTES,
    ElevenLabsVoice, seed_for_speech_text,
)

TOKEN = "test-backend-token-that-is-long-enough"


class FakeResponse:
    def __init__(self, payload, headers=None):
        self.payload = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        self.headers = Message()
        self.headers["Content-Type"] = "application/json"
        for name, value in (headers or {}).items():
            self.headers[name] = str(value)

    def read(self, size=-1):
        return self.payload if size < 0 else self.payload[:size]

    def __enter__(self):
        return self

    def __exit__(self, *unused):
        return False


class FakeSpeech:
    def __init__(self):
        self.calls = []

    def speak(self, text, emotion):
        self.calls.append((text, emotion))
        return {"audio_base64": "c291bmQ="}


def provider_body(audio=b"ID3-test", alignment=None):
    result = {"audio_base64": base64.b64encode(audio).decode()}
    if alignment is not None:
        result["alignment"] = alignment
    return result


class VoiceAdapterTests(unittest.TestCase):
    def test_neutral_is_untagged_and_disgust_has_its_own_delivery(self):
        voice = ElevenLabsVoice("test-key", "test-voice")
        for emotion in ("neutral", "joy", "sadness", "anger", "fear", "disgust"):
            with self.subTest(emotion=emotion):
                with mock.patch("backend.voice._PROVIDER_OPENER.open", return_value=FakeResponse(provider_body())) as request:
                    voice.speak("Hello.", emotion)
                payload = json.loads(request.call_args.args[0].data)
                self.assertTrue(payload["text"].endswith("Hello."))
                if emotion == "neutral":
                    self.assertEqual(payload["text"], "Hello.")
                    self.assertEqual(payload["voice_settings"]["style"], 0)
                if emotion == "disgust":
                    self.assertEqual(payload["text"], "[disgusted] Hello.")
                self.assertEqual(payload["seed"], seed_for_speech_text("Hello.", emotion))

    def test_request_matches_frontend_contract_and_validates_response(self):
        alignment = {
            "characters": ["[", "h", "i", "]", " ", "H"],
            "character_start_times_seconds": [0, .01, .02, .03, .04, .05],
            "character_end_times_seconds": [.01, .02, .03, .04, .05, .2],
        }
        response = FakeResponse(provider_body(alignment=alignment))
        voice = ElevenLabsVoice("provider-key-not-for-client", "voice/a ?")
        with mock.patch("backend.voice._PROVIDER_OPENER.open", return_value=response) as open_mock:
            result = voice.speak("  Hello 😀  ", "fear")
        request = open_mock.call_args.args[0]
        self.assertEqual(
            request.full_url,
            ELEVENLABS_URL + "voice%2Fa%20%3F/with-timestamps?output_format=mp3_44100_128")
        self.assertEqual(open_mock.call_args.kwargs["timeout"], 20)
        self.assertEqual(request.get_header("Accept"), "application/json")
        self.assertEqual(request.get_header("Xi-api-key"), "provider-key-not-for-client")
        payload = json.loads(request.data)
        self.assertEqual(payload["text"], "[worried] [nervously] Hello 😀")
        self.assertEqual(payload["model_id"], "eleven_v3")
        self.assertEqual(payload["seed"], seed_for_speech_text("Hello 😀", "fear"))
        self.assertEqual(payload["voice_settings"], {
            "stability": 0, "similarity_boost": .64, "style": .78, "speed": 1.2,
            "use_speaker_boost": True})
        self.assertEqual(result["alignment"], alignment)
        self.assertNotIn("provider-key-not-for-client", json.dumps(result))

    def test_rejects_invalid_input_before_any_provider_request(self):
        voice = ElevenLabsVoice("key", "voice")
        with mock.patch("backend.voice._PROVIDER_OPENER.open") as open_mock:
            for text, emotion in ((None, "joy"), ("   ", "joy"), ("x"*501, "joy"),
                                  ("hello", "confused"), ("hello", None)):
                with self.subTest(text=type(text), emotion=emotion):
                    with self.assertRaises(ServiceError) as context:
                        voice.speak(text, emotion)
                    self.assertEqual(context.exception.status, 400)
        open_mock.assert_not_called()

    def test_provider_errors_and_malformed_or_oversized_responses_are_safe(self):
        key = "provider-key-must-not-leak"
        voice = ElevenLabsVoice(key, "voice-id")
        http_error = urllib.error.HTTPError("https://provider.invalid", 401, "no", {}, None)
        cases = [
            ("http", http_error, "upstream_http"),
            ("invalid-json", FakeResponse(b"{not-json"), "upstream"),
            ("bad-base64", FakeResponse({"audio_base64": "not base64!"}), "upstream_schema"),
            ("bad-alignment", FakeResponse(provider_body(alignment={
                "characters": ["a"], "character_start_times_seconds": [1],
                "character_end_times_seconds": [0]})), "upstream_schema"),
            ("declared-oversized", FakeResponse(provider_body(), {
                "Content-Length": MAX_UPSTREAM_RESPONSE_BYTES + 1}), "upstream"),
            ("encoded-audio-oversized", FakeResponse({
                "audio_base64": "A" * (MAX_AUDIO_BASE64_CHARACTERS + 1)}), "upstream_schema"),
        ]
        for name, outcome, code in cases:
            with self.subTest(name=name):
                patch = {"side_effect": outcome} if isinstance(outcome, BaseException) else {"return_value": outcome}
                with mock.patch("backend.voice._PROVIDER_OPENER.open", **patch):
                    with self.assertRaises(ServiceError) as context:
                        voice.speak("private text")
            self.assertEqual(context.exception.code, code)
            self.assertEqual(context.exception.status, 502)
            self.assertNotIn(key, context.exception.message)
            self.assertNotIn("private text", context.exception.message)
        with mock.patch("backend.voice._PROVIDER_OPENER.open", side_effect=TimeoutError()):
            with self.assertRaises(ServiceError) as context:
                voice.speak("private text")
        self.assertEqual(context.exception.code, "upstream")

    def test_redirect_to_another_origin_fails_without_a_second_request(self):
        source_requests, redirected_requests = [], []

        class RedirectSource(BaseHTTPRequestHandler):
            def do_POST(self):
                source_requests.append(dict(self.headers))
                self.send_response(302)
                self.send_header("Location", f"http://127.0.0.1:{redirected.server_port}/stolen")
                self.send_header("Content-Length", "0")
                self.end_headers()

            def log_message(self, *unused):
                pass

        class RedirectTarget(BaseHTTPRequestHandler):
            def do_POST(self):
                redirected_requests.append(dict(self.headers))
                self.send_response(204)
                self.end_headers()

            def log_message(self, *unused):
                pass

        redirected = ThreadingHTTPServer(("127.0.0.1", 0), RedirectTarget)
        source = ThreadingHTTPServer(("127.0.0.1", 0), RedirectSource)
        threads = [threading.Thread(target=server.serve_forever, daemon=True)
                   for server in (redirected, source)]
        for thread in threads:
            thread.start()
        try:
            # The production constant remains HTTPS ElevenLabs. Only this local
            # regression test substitutes its trusted source with a local server.
            local_url = f"http://127.0.0.1:{source.server_port}/v1/text-to-speech/"
            with mock.patch("backend.voice.ELEVENLABS_URL", local_url):
                with self.assertRaises(ServiceError) as context:
                    ElevenLabsVoice("provider-key-private", "voice").speak("private text")
            self.assertEqual(context.exception.code, "upstream_http")
            self.assertIn("HTTP 302", context.exception.message)
            self.assertEqual(source_requests[0]["Xi-Api-Key"], "provider-key-private")
            self.assertEqual(redirected_requests, [])
        finally:
            for server in (source, redirected):
                server.shutdown()
            for thread in threads:
                thread.join(timeout=2)
            for server in (source, redirected):
                server.server_close()

    def test_config_requires_both_server_side_values(self):
        for key, voice_id in (("", "voice"), ("key", "")):
            with self.subTest(key=bool(key), voice_id=bool(voice_id)):
                with self.assertRaises(ServiceError) as context:
                    ElevenLabsVoice(key, voice_id)
                self.assertEqual(context.exception.status, 503)


class VoiceServerTests(unittest.TestCase):
    def test_all_expression_labels_and_neutral_default_reach_speech(self):
        speech = FakeSpeech()
        base = self.start_server(speech)
        for emotion in ("neutral", "joy", "sadness", "anger", "fear", "disgust"):
            status, _ = self.request(base, "/v1/speech", {"text": "Hello.", "emotion": emotion})
            self.assertEqual(status, 200)
            self.assertEqual(speech.calls[-1], ("Hello.", emotion))
        status, _ = self.request(base, "/v1/speech", {"text": "Hello."})
        self.assertEqual(status, 200)
        self.assertEqual(speech.calls[-1], ("Hello.", "neutral"))

    def start_server(self, speech=None):
        server = make_server("127.0.0.1", 0, None, TOKEN, speech)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()

        def stop():
            server.shutdown()
            thread.join(timeout=2)
            server.server_close()
        self.addCleanup(stop)
        return f"http://127.0.0.1:{server.server_port}"

    @staticmethod
    def request(base, path, payload=None, token=TOKEN):
        headers = {"Content-Type": "application/json"}
        if token is not None:
            headers["Authorization"] = "Bearer " + token
        connection = http.client.HTTPConnection(base.removeprefix("http://"), timeout=5)
        try:
            connection.request("POST" if payload is not None else "GET", path,
                               body=None if payload is None else json.dumps(payload).encode(), headers=headers)
            response = connection.getresponse()
            return response.status, json.loads(response.read())
        finally:
            connection.close()

    def test_voice_only_health_status_and_route_availability(self):
        speech = FakeSpeech()
        base = self.start_server(speech)
        with urllib.request.urlopen(base + "/health") as response:
            health = json.load(response)
        self.assertEqual(health["classifier"], "unavailable")
        self.assertIsNone(health["caption_provider"])
        self.assertEqual(health["speech"], "elevenlabs")
        status, body = self.request(base, "/v1/status", None)
        self.assertEqual(status, 200)
        self.assertEqual(body["mode"], "unavailable")
        self.assertFalse(body["classifier"])
        self.assertFalse(body["caption"])
        self.assertTrue(body["speech"])
        self.assertEqual(self.request(base, "/v1/classify", {"frames": []})[0], 503)
        self.assertEqual(self.request(base, "/v1/caption", {"raw_signs": []})[0], 503)
        status, body = self.request(base, "/v1/speech", {"text": "Hello"})
        self.assertEqual((status, body), (200, {"audio_base64": "c291bmQ="}))
        self.assertEqual(speech.calls, [("Hello", "neutral")])

    def test_speech_auth_and_input_validation(self):
        speech = FakeSpeech()
        base = self.start_server(speech)
        status, body = self.request(base, "/v1/speech", {"text": "Hello"}, token=None)
        self.assertEqual((status, body["error"]), (401, "unauthorized"))
        self.assertFalse(speech.calls)
        for payload in ({"text": ""}, {"text": "x"*501}, {"text": "Hi", "emotion": "other"}):
            with self.subTest(payload=payload):
                status, body = self.request(base, "/v1/speech", payload)
                self.assertEqual((status, body["error"]), (400, "speech"))
        self.assertFalse(speech.calls)
        unavailable = self.start_server()
        status, body = self.request(unavailable, "/v1/speech", {"text": "Hello"})
        self.assertEqual((status, body["error"]), (503, "speech_unavailable"))

    def test_provider_error_response_does_not_expose_credentials_or_text(self):
        key, voice_id, text = "provider-key-private", "voice-id-private", "private speech text"
        speech = ElevenLabsVoice(key, voice_id)
        base = self.start_server(speech)
        provider_error = urllib.error.HTTPError("https://provider.invalid", 403, "no", {}, None)
        with mock.patch("backend.voice._PROVIDER_OPENER.open", side_effect=provider_error):
            status, body = self.request(base, "/v1/speech", {"text": text})
        serialized = json.dumps(body)
        self.assertEqual((status, body["error"]), (502, "upstream_http"))
        for secret in (key, voice_id, text):
            self.assertNotIn(secret, serialized)

    def test_loopback_browser_preview_can_call_speech(self):
        speech = FakeSpeech()
        base = self.start_server(speech)
        origin = "http://localhost:8083"
        connection = http.client.HTTPConnection(base.removeprefix("http://"), timeout=5)
        try:
            connection.request("OPTIONS", "/v1/speech", headers={
                "Origin": origin, "Access-Control-Request-Method": "POST",
                "Access-Control-Request-Headers": "authorization,content-type"})
            preflight = connection.getresponse()
            self.assertEqual(preflight.status, 204)
            self.assertEqual(preflight.getheader("Access-Control-Allow-Origin"), origin)
            self.assertIn("authorization", (preflight.getheader("Access-Control-Allow-Headers") or "").lower())
            preflight.read()
            connection.request("POST", "/v1/speech", body=json.dumps({"text": "Hello"}).encode(), headers={
                "Content-Type": "application/json", "Authorization": "Bearer " + TOKEN, "Origin": origin})
            response = connection.getresponse()
            body = json.loads(response.read())
            self.assertEqual(response.status, 200)
            self.assertEqual(response.getheader("Access-Control-Allow-Origin"), origin)
            self.assertEqual(body, {"audio_base64": "c291bmQ="})
        finally:
            connection.close()
        remote = http.client.HTTPConnection(base.removeprefix("http://"), timeout=5)
        try:
            remote.request("OPTIONS", "/v1/speech", headers={"Origin": "https://example.com"})
            self.assertEqual(remote.getresponse().status, 403)
        finally:
            remote.close()


if __name__ == "__main__":
    unittest.main()
