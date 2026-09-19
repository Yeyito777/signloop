"""Articulation mechanics only: synthetic geometry is not ASL accuracy."""
import copy
import unittest

from .research_motion import pinch_motion, MotionMatcher, challenges, choose
from .test_matcher import geometry


def articulation():
    data = geometry()
    for i, frame in enumerate(data):
        for index in (8, 12):
            frame["hands"][0]["joints"][index]["x"] += .08*i/(len(data)-1)
    return data


class Tests(unittest.TestCase):
    def test_rigid_translation_is_not_articulation(self):
        self.assertLess(pinch_motion(geometry()), 1e-12)
        self.assertGreater(pinch_motion(articulation()), .3)

    def test_reflection_scale_and_translation_invariance(self):
        data = articulation()
        changed = copy.deepcopy(data)
        for frame in changed:
            frame["mirrored"] = False
            frame["hands"][0]["handedness"] = "Left"
            for p in frame["hands"][0]["joints"]:
                p["x"], p["y"] = 1-.6*p["x"], .1+.6*p["y"]
        self.assertAlmostEqual(pinch_motion(data), pinch_motion(changed))

    def test_aspect_correction(self):
        data = articulation()
        wide = copy.deepcopy(data)
        for frame in wide:
            frame["imageAspectRatio"] = 2
            for p in frame["hands"][0]["joints"]:
                p["x"] /= 2
        self.assertAlmostEqual(pinch_motion(data), pinch_motion(wide))

    def test_missing_duplicate_and_tracking_gap_do_not_bridge(self):
        for kind in ("missing", "duplicate", "gap", "metadata"):
            data = articulation()[:10]
            if kind == "missing":
                data[4]["hands"] = []
            elif kind == "duplicate":
                data[4]["hands"] *= 2
            elif kind == "gap":
                for frame in data[5:]:
                    frame["timestampMS"] += 300
            else:
                for frame in data[5:]:
                    frame["mirrored"] = False
            self.assertEqual(pinch_motion(data), 0)

    def test_single_spike_suppressed_and_degenerate_rejected(self):
        data = geometry()
        data[7]["hands"][0]["joints"][8]["x"] += 1
        self.assertLess(pinch_motion(data), 1e-12)
        for frame in data:
            frame["hands"][0]["joints"][9] = frame["hands"][0]["joints"][0].copy()
        self.assertEqual(pinch_motion(data), 0)

    def test_guard_only_rejects_no_never_promotes_unknown(self):
        matcher = object.__new__(MotionMatcher)
        matcher.min_score, matcher.min_margin, matcher.min_motion = .4, .05, .075
        def decision(label, motion, score=.9):
            return matcher.decide([{"label": label, "score": score, "pinch_motion": motion},
                                   {"label": "OTHER", "score": .01}])
        self.assertTrue(decision("NO", .07499)["unknown"])
        self.assertFalse(decision("NO", .075)["unknown"])
        self.assertFalse(decision("HELLO", 0)["unknown"])
        self.assertTrue(decision("NO", 1, .2)["unknown"])
        self.assertTrue(decision("UNSUPPORTED:cat", 1)["unknown"])

    def test_probe_seed_and_count(self):
        samples = [{"frames": geometry()}]
        a, b = list(challenges(samples)), list(challenges(samples))
        self.assertEqual(a, b)
        self.assertEqual(len(a), 12)
        self.assertTrue(all(len(frames) == 19 for _, frames in a))

    def test_calibration_cannot_ignore_non_no_false_accept(self):
        matcher = object.__new__(MotionMatcher)
        matcher.min_score, matcher.min_margin = .4, .05
        ranks = [{"label": "HELLO", "score": .9}, {"label": "OTHER", "score": .01}]
        with self.assertRaises(ValueError):
            choose([], [(0, ranks)], matcher)


if __name__ == "__main__":
    unittest.main()
