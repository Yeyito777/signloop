import json
import threading
import unittest
import urllib.error
import urllib.request

from .service import (
    Backboard, Service, ServiceError, SIGN_CRITERIA, parse_decision, summarize, validate_frames,
)
from .server import make_server


def frames():
    joints = [{"x": 0.5 + index * .005, "y": 0.5 + index * .01, "z": 0} for index in range(21)]
    return [{"timestampMS": index * 100, "hands": [
        {"handedness": "Left", "handednessScore": .9, "joints": joints}]} for index in range(12)]


def decision(scores=None, choice="HELLO"):
    return {"system_one": {"model": "test-jev", "answers": {"sign": {
        "type": "choice", "choice": choice, "probabilities": scores or {
            **{label: 0 for label in SIGN_CRITERIA}, "HELLO": .95, "UNKNOWN": .05},
    }}}}


class FakeGateway:
    def __init__(self, response):
        self.response, self.calls = response, []

    def message(self, payload, provider):
        self.calls.append((provider, payload))
        return self.response


class Tests(unittest.TestCase):
    def test_validate_and_normalize(self):
        data = validate_frames(frames())
        summary = summarize(data)
        self.assertEqual(len(summary), 4)
        self.assertEqual(summary[0]["hands"][0]["normalized_xyz"][0], [0, 0, 0])
        self.assertEqual(summary[-1]["t_ms"], 1100)

    def test_invalid_inputs(self):
        for data in (None, [{}], frames() * 10, [{"timestampMS": -1, "hands": []}]):
            with self.subTest(data=type(data)), self.assertRaises(ServiceError):
                validate_frames(data)
        data = frames()
        data[0]["hands"][0]["joints"][0]["x"] = float("nan")
        with self.assertRaises(ServiceError):
            validate_frames(data)

    def test_no_hand_no_external_call(self):
        gateway = FakeGateway({})
        service = Service(gateway)
        self.assertEqual(service.classify([])["reason"], "no_hands")
        self.assertFalse(gateway.calls)

    def test_real_adapter_schema_and_abstention(self):
        gateway = FakeGateway(decision())
        result = Service(gateway).classify(frames())
        self.assertFalse(result["unknown"])
        self.assertEqual(result["mode"], "zero_shot")
        provider, request = gateway.calls[0]
        self.assertEqual(provider, "typesafe")
        self.assertIn("UNKNOWN", request["system_one"]["questions"]["sign"]["criteria"])
        self.assertNotIn("response_format", request)
        self.assertNotIn("references", request["system_one"]["state"])
        self.assertEqual(set(request["system_one"]["questions"]["sign"]["criteria"]), set(SIGN_CRITERIA) | {"UNKNOWN"})
        self.assertTrue(parse_decision(decision({"HELLO": .55, "UNKNOWN": .45}), {"HELLO"})["unknown"])
        with self.assertRaises(ServiceError):
            parse_decision(decision({"HELLO": float("nan"), "UNKNOWN": .05}), {"HELLO"})
        with self.assertRaises(ServiceError):
            parse_decision(decision({"HELLO": .1, "UNKNOWN": .9}), {"HELLO"})

    def test_caption_exact_meaning_guard(self):
        gateway = FakeGateway({"content": json.dumps({"text": "Hello! Thank you.", "raw_signs": ["HELLO", "THANK_YOU"]}),
                               "model_name": "test-caption"})
        service = Service(gateway)
        self.assertTrue(service.caption(["HELLO", "THANK_YOU"])["polished"])
        gateway.response["content"] = json.dumps({"text": "Hello, thank you for helping me.", "raw_signs": ["HELLO", "THANK_YOU"]})
        result = service.caption(["HELLO", "THANK_YOU"])
        self.assertFalse(result["polished"])
        self.assertEqual(result["text"], "Hello. Thank you.")
        with self.assertRaises(ServiceError):
            service.caption(["invent something"])
        with self.assertRaises(ServiceError):
            service.caption([{}])
        self.assertEqual(service.caption([])["text"], "")

    def test_http_200_failed_provider_is_error(self):
        gateway = Backboard("fake-test-key")
        gateway.request = lambda *args: {"status": "FAILED", "content": "secret provider error"}
        with self.assertRaises(ServiceError) as context:
            gateway.message({}, "cerebras")
        self.assertNotIn("secret", str(context.exception))

    def test_http_auth_validation_and_no_hand(self):
        service = Service(FakeGateway({}))
        token = "test-token-not-real-secret-long"
        server = make_server("127.0.0.1", 0, service, token)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        base = f"http://127.0.0.1:{server.server_port}"
        with urllib.request.urlopen(base + "/health") as response:
            self.assertEqual(json.load(response)["status"], "ok")
        with self.assertRaises(urllib.error.HTTPError) as error:
            urllib.request.urlopen(base + "/v1/status")
        self.assertEqual(error.exception.code, 401)
        error.exception.close()
        request = urllib.request.Request(base + "/v1/classify", data=b'{"frames":[]}',
                                        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
        with urllib.request.urlopen(request) as response:
            self.assertEqual(json.load(response)["reason"], "no_hands")
        request = urllib.request.Request(base + "/v1/references", data=b'{}',
                                        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
        with self.assertRaises(urllib.error.HTTPError) as error:
            urllib.request.urlopen(request)
        self.assertEqual(error.exception.code, 404)
        error.exception.close()


if __name__ == "__main__":
    unittest.main()
