"""Synthetic geometry tests ONLY. These fixtures are NOT examples of ASL."""
import copy
import hashlib
import json
import math
from pathlib import Path
import tempfile
import threading
import unittest
import urllib.request

from .matcher import ReferenceMatcher, ReferenceService, dtw, features, load_corpus
from .replay import evaluate
from .server import make_server, reference_service
from .service import ServiceError


def geometry(kind=0, count=16, offset=0., scale=1., reverse=False):
    frames = []
    for i in range(count):
        t = i / (count-1)
        if reverse:
            t = 1-t
        wrist = (.4 + .06 * math.sin(math.pi * t), .7 - .15*t)
        joints = []
        for j in range(21):
            # Deliberately artificial, with controllable shape differences.
            x = wrist[0] + (j % 4) * .01 + (kind * .045 if j > 10 else 0)
            y = wrist[1] - j * .01
            joints.append({"x": offset + scale*x, "y": offset + scale*y, "z": 0.})
        frames.append({"timestampMS": round(t*1200) if not reverse else round((1-t)*1200),
                       "hands": [{"handedness": "Right", "joints": joints}]})
    return frames


def sample(identifier, label, frames, split="train", signer=None):
    return {"id": identifier, "label": label, "frames": frames, "split": split,
            "source": "SYNTHETIC_GEOMETRY_NOT_ASL", "signer": signer or split}


def matcher():
    return ReferenceMatcher([sample("a", "YES", geometry(0)), sample("b", "NO", geometry(3))],
                            max_distance=.1, min_margin=.15)


class Tests(unittest.TestCase):
    def test_scale_translation_and_speed(self):
        a = features(geometry())
        b = features(geometry(count=23, scale=.7, offset=.1))
        self.assertLess(dtw(a, b), .025)
        self.assertAlmostEqual(dtw(a, a), 0)

    def test_motion_order_not_erased(self):
        self.assertGreater(dtw(features(geometry()), features(geometry(reverse=True))), .1)

    def test_orientation_preserved(self):
        rotated = geometry()
        for f in rotated:
            for j in f["hands"][0]["joints"]:
                j["x"], j["y"] = j["y"], 1-j["x"]
        self.assertGreater(dtw(features(geometry()), features(rotated)), .1)

    def test_aspect_and_mirror_canonicalization(self):
        canonical, wide, unmirrored = geometry(), geometry(), geometry()
        for f in wide:
            f["imageAspectRatio"] = 2
            for j in f["hands"][0]["joints"]:
                j["x"] /= 2
                j["z"] /= 2
        for f in unmirrored:
            f["mirrored"] = False
            f["hands"][0]["handedness"] = "Left"
            for j in f["hands"][0]["joints"]:
                j["x"] = 1-j["x"]
        self.assertAlmostEqual(dtw(features(canonical), features(wide)), 0)
        self.assertAlmostEqual(dtw(features(canonical), features(unmirrored)), 0)

    def test_accept_reject_and_diagnostics(self):
        m = matcher()
        result = m.classify(geometry(count=20))
        self.assertFalse(result["unknown"])
        self.assertEqual(result["candidates"][0]["label"], "YES")
        self.assertEqual(result["diagnostics"]["score_kind"], "exp_negative_distance")
        self.assertEqual(m.classify(geometry(20))["reason"], "too_distant")
        m = ReferenceMatcher([sample("a", "YES", geometry()), sample("b", "NO", geometry())], .2, .1)
        self.assertEqual(m.classify(geometry())["reason"], "ambiguous")

    def test_no_hand_degenerate_and_invalid(self):
        m = matcher()
        self.assertTrue(m.classify([])["unknown"])
        self.assertTrue(m.classify([{"timestampMS": i, "hands": []} for i in range(10)])["unknown"])
        for field, value in (("imageAspectRatio", float("nan")), ("mirrored", "true")):
            data = geometry()
            data[0][field] = value
            with self.assertRaises(ServiceError):
                m.classify(data)
        data = geometry()
        data[-1]["hands"] = []
        self.assertTrue(m.classify(data)["unknown"])
        for f in data:
            f["hands"] = [{"handedness": "Right", "joints": [{"x": .5, "y": .5, "z": 0}] * 21}]
        self.assertTrue(m.classify(data)["unknown"])

    def test_two_hand_visibility_not_ignored(self):
        a, b = geometry(), geometry()
        for f in b:
            second = copy.deepcopy(f["hands"][0])
            second["handedness"] = "Left"
            f["hands"].append(second)
        self.assertGreater(dtw(features(a), features(b)), .5)

    def test_ambiguous_hand_identity_is_reported(self):
        data = geometry()
        data[5]["hands"].append(copy.deepcopy(data[5]["hands"][0]))
        result = matcher().classify(data)
        self.assertTrue(result["unknown"])
        self.assertEqual(result["reason"], "ambiguous_hand_identity")
        self.assertEqual(result["diagnostics"]["frame_count"], 16)
        self.assertEqual(matcher().classify(geometry(count=4))["reason"], "insufficient_frames")

    def test_signer_and_duplicate_leakage(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "corpus.json"
            rows = [sample("a", "YES", geometry(), signer="p"),
                    sample("b", "YES", geometry(1), split="test", signer="p")]
            path.write_text(json.dumps({"version": 1, "samples": rows}))
            with self.assertRaisesRegex(ValueError, "Signer"):
                load_corpus(path)
            rows[1]["signer"] = "q"
            rows[1]["frames"] = geometry()
            path.write_text(json.dumps({"version": 1, "samples": rows}))
            with self.assertRaisesRegex(ValueError, "Duplicate recording geometry"):
                load_corpus(path)

    def test_calibration_excludes_test(self):
        rows = []
        for split, count in (("train", 16), ("calibration", 19), ("test", 21)):
            for kind, label in ((0, "YES"), (3, "NO"), (20, "UNKNOWN")):
                if split == "train" and label == "UNKNOWN":
                    continue
                rows.append(sample(f"{split}-{kind}", label, geometry(kind, count), split))
        corpus = {"samples": rows}
        report = evaluate(corpus, "test-digest")
        self.assertEqual(report["test"]["known_accuracy"], 1)
        self.assertEqual(report["test"]["unknown_false_accept_rate"], 0)
        for s in rows:
            if s["split"] == "test":
                s["frames"] = geometry(100)
        changed = evaluate(corpus, "test-digest")
        self.assertEqual(report["parameters"], changed["parameters"])

    def test_reference_http_no_gateway(self):
        server = make_server("127.0.0.1", 0, ReferenceService(matcher()), "x"*32)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        req = urllib.request.Request(f"http://127.0.0.1:{server.server_port}/v1/classify",
                                     data=json.dumps({"frames": geometry()}).encode(),
                                     headers={"Authorization": "Bearer " + "x"*32,
                                              "Content-Type": "application/json"})
        with urllib.request.urlopen(req) as r:
            response = json.load(r)
        self.assertFalse(response["unknown"])
        self.assertEqual(response["mode"], "reference_dtw")

    def test_report_binding_and_restricted_corpus(self):
        with tempfile.TemporaryDirectory() as d:
            corpus = Path(d) / "corpus.json"
            report = Path(d) / "report.json"
            corpus.write_text(json.dumps({"version": 1, "redistribution": "PROHIBITED", "samples": [
                sample("a", "YES", geometry()), sample("b", "NO", geometry(3))]}))
            report.write_text(json.dumps({"model": "reference-dtw-v1", "corpus_sha256": "wrong",
                                         "parameters": {"max_distance": .1, "min_margin": .1}}))
            with self.assertRaisesRegex(ValueError, "loopback"):
                reference_service(corpus, report, "0.0.0.0")
            with self.assertRaisesRegex(ValueError, "does not match"):
                reference_service(corpus, report, "127.0.0.1")
            r = json.loads(report.read_text())
            r["corpus_sha256"] = hashlib.sha256(corpus.read_bytes()).hexdigest()
            report.write_text(json.dumps(r))
            self.assertEqual(reference_service(corpus, report, "127.0.0.1").mode, "reference_dtw")


if __name__ == "__main__":
    unittest.main()
