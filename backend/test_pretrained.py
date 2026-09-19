"""Pure contract/rejection tests, no model downloads or ASL accuracy claims."""
import math
import copy
from pathlib import Path
import tempfile
import unittest

from .research_pretrained import PretrainedResearchMatcher, ranked_logits, calibrate
from .test_matcher import geometry

try:
    import numpy as np
except ImportError:
    np = None


def vocabulary():
    return {**{f"other{i}": i for i in range(5, 250)},
            "hello": 0, "yes": 1, "no": 2, "please": 3, "thankyou": 4}


class Tests(unittest.TestCase):
    def test_unrecognized_asset_rejected_before_loading(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "invalid.tflite"
            path.write_bytes(b"not the pinned model")
            with self.assertRaisesRegex(ValueError, "Unrecognized"):
                PretrainedResearchMatcher(path, path)

    def test_all_250_labels_compete(self):
        logits = [0.]*250
        logits[20], logits[0] = 5, 2
        ranked = ranked_logits(logits, vocabulary())
        self.assertTrue(ranked[0]["label"].startswith("UNSUPPORTED:"))
        matcher = object.__new__(PretrainedResearchMatcher)
        matcher.min_score = matcher.min_margin = 0
        self.assertTrue(matcher.decide(ranked)["unknown"])
        self.assertEqual(ranked[1]["label"], "HELLO")

    def test_stable_softmax_and_input_rejection(self):
        base = list(range(250))
        a = ranked_logits(base, vocabulary())
        b = ranked_logits([x+10000 for x in base], vocabulary())
        self.assertEqual(a, b)
        for logits in ([0.]*249, [math.nan]*250, [math.inf]*250):
            with self.assertRaises(ValueError):
                ranked_logits(logits, vocabulary())
        with self.assertRaises(ValueError):
            ranked_logits(base, {})

    def test_score_margin_and_empty_rejection(self):
        matcher = object.__new__(PretrainedResearchMatcher)
        matcher.min_score, matcher.min_margin = .5, .2
        self.assertTrue(matcher.decide([])["unknown"])
        self.assertTrue(matcher.decide([{"label": "YES", "score": .5},
                                       {"label": "NO", "score": .1}])["unknown"])
        self.assertTrue(matcher.decide([{"label": "YES", "score": .6},
                                       {"label": "NO", "score": .5}])["unknown"])
        self.assertFalse(matcher.decide([{"label": "YES", "score": .8},
                                        {"label": "NO", "score": .1}])["unknown"])

    def test_calibration_constrains_both_error_types(self):
        matcher = object.__new__(PretrainedResearchMatcher)
        def run(truth, score):
            return {"truth": truth, "events": [
                {"reset": False, "t_ms": t, "ranked": [
                    {"label": "YES", "score": score}, {"label": "NO", "score": .05}]}
                for t in (300, 600)]}
        policy = calibrate([run("YES", .9), run("NO", .7), run("UNKNOWN", .6)], matcher)
        self.assertGreaterEqual(policy["min_score"], .7)
        self.assertLess(policy["min_score"], .9)


@unittest.skipIf(np is None, "Optional research NumPy not installed")
class TensorTests(unittest.TestCase):
    def setUp(self):
        self.matcher = object.__new__(PretrainedResearchMatcher)
        self.matcher.np = np

    def test_layout_missing_face_and_shape(self):
        tensor = self.matcher.tensor(geometry())
        self.assertEqual(tensor.shape, (16, 543, 3))
        self.assertEqual(tensor.dtype, np.float32)
        self.assertTrue(np.isnan(tensor[:, :522]).all())
        self.assertTrue(np.isfinite(tensor[:, 522:]).all())

    def test_no_hands_short_and_sparse_rejected(self):
        self.assertIsNone(self.matcher.tensor([]))
        self.assertIsNone(self.matcher.tensor(geometry(count=4)))
        data = geometry()
        for frame in data[:-1]:
            frame["hands"] = []
        self.assertIsNone(self.matcher.tensor(data))
        data = geometry()
        data[-1]["hands"] = []
        self.assertIsNone(self.matcher.tensor(data))

    def test_mirroring_metadata_canonicalization(self):
        a = geometry()
        b = copy.deepcopy(a)
        for frame in b:
            frame["mirrored"] = False
            frame["hands"][0]["handedness"] = "Left"
            for p in frame["hands"][0]["joints"]:
                p["x"] = 1-p["x"]
        np.testing.assert_allclose(self.matcher.tensor(a), self.matcher.tensor(b), equal_nan=True)

    def test_duplicate_identity_order_independence(self):
        data = geometry()
        for frame in data:
            second = copy.deepcopy(frame["hands"][0])
            second["joints"][20]["x"] += .01
            frame["hands"].append(second)
        a = self.matcher.tensor(data)
        for frame in data:
            frame["hands"].reverse()
        np.testing.assert_array_equal(a, self.matcher.tensor(data))


if __name__ == "__main__":
    unittest.main()
