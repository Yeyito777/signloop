import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from .matcher import MirroredReferenceMatcher, TrackedReferenceMatcher, reflect_hands
from .stream_calibrate import choose, decide_runs, evaluate
from .server import reference_service
from .test_matcher import geometry, sample


class Tests(unittest.TestCase):
    def test_reflection_involution_and_no_mutation(self):
        source = geometry()
        original = copy.deepcopy(source)
        reflected = reflect_hands(source)
        self.assertEqual(source, original)
        self.assertEqual(reflected[0]["hands"][0]["handedness"], "Left")
        restored = reflect_hands(reflected)
        for a, b in zip(source, restored):
            for x, y in zip(a["hands"][0]["joints"], b["hands"][0]["joints"]):
                self.assertAlmostEqual(x["x"], y["x"])
                self.assertEqual(x["y"], y["y"])
                self.assertEqual(x["z"], y["z"])

    def test_mirror_augments_hand_not_sign_label(self):
        rows = [sample("a", "YES", geometry()), sample("b", "NO", geometry(3))]
        base = TrackedReferenceMatcher(rows, .1, .1)
        mirrored = MirroredReferenceMatcher(rows, .1, .1)
        query = reflect_hands(geometry())
        self.assertTrue(base.classify(query)["unknown"])
        decision = mirrored.classify(query)
        self.assertFalse(decision["unknown"])
        self.assertEqual(decision["candidates"][0]["label"], "YES")
        self.assertEqual(len(mirrored.references), 2*len(base.references))
        rows[1]["label"] = "TURN_LEFT"
        with self.assertRaisesRegex(ValueError, "restricted"):
            MirroredReferenceMatcher(rows, .1, .1)

    def test_calibration_constrains_wrong_known_not_only_unknown(self):
        matcher = TrackedReferenceMatcher(
            [sample("a", "YES", geometry()), sample("b", "NO", geometry(3))], 0, 1)
        def run(truth, distance):
            ranked = [{"label": "YES", "distance": distance}, {"label": "NO", "distance": 1}]
            return {"truth": truth, "events": [
                {"t_ms": 300, "reset": False, "ranked": ranked},
                {"t_ms": 600, "reset": False, "ranked": ranked}]}
        prepared = [run("YES", .1), run("NO", .3), run("UNKNOWN", .5)]
        distance, _ = choose(prepared, matcher)
        self.assertLess(distance, .3)
        decisions = decide_runs(prepared, matcher)
        self.assertTrue(decisions[0]["onsets"])
        self.assertFalse(decisions[1]["onsets"])
        self.assertFalse(decisions[2]["onsets"])

    def test_reject_all_when_correct_and_wrong_evidence_identical(self):
        matcher = TrackedReferenceMatcher(
            [sample("a", "YES", geometry()), sample("b", "NO", geometry(3))], 0, 1)
        ranks = [{"label": "YES", "distance": .1}, {"label": "NO", "distance": .8}]
        events = [{"t_ms": t, "reset": False, "ranked": ranks} for t in (300, 600)]
        prepared = [{"truth": truth, "events": events} for truth in ("YES", "UNKNOWN")]
        choose(prepared, matcher)
        self.assertTrue(all(not r["onsets"] for r in decide_runs(prepared, matcher)))

    def test_selection_ignores_test_geometry(self):
        rows = []
        for split, count in (("train", 16), ("calibration", 19), ("test", 21)):
            for kind, label in ((0, "YES"), (3, "NO"), (20, "UNKNOWN")):
                if split == "train" and label == "UNKNOWN":
                    continue
                rows.append(sample(f"{split}-{label}", label, geometry(kind, count), split))
        report = evaluate({"samples": rows}, "synthetic", "reference-dtw-v2")
        for row in rows:
            if row["split"] == "test":
                row["frames"] = geometry(100)
        altered = evaluate({"samples": rows}, "synthetic", "reference-dtw-v2")
        self.assertEqual(report["parameters"], altered["parameters"])
        self.assertEqual(report["calibration"], altered["calibration"])

    def test_legacy_server_refuses_streaming_policy_mismatch(self):
        with tempfile.TemporaryDirectory() as directory:
            corpus = Path(directory) / "corpus.json"
            report = Path(directory) / "report.json"
            corpus.write_text(json.dumps({"version": 1, "samples": [
                sample("a", "YES", geometry()), sample("b", "NO", geometry(3))]}))
            report.write_text(json.dumps({
                "protocol": "rolling-calibration-v1", "model": "reference-dtw-v2",
                "corpus_sha256": hashlib.sha256(corpus.read_bytes()).hexdigest(),
                "parameters": {"max_distance": .1, "min_margin": .1}}))
            with self.assertRaisesRegex(ValueError, "cadence/filter"):
                reference_service(corpus, report, "127.0.0.1")


if __name__ == "__main__":
    unittest.main()
