import time
import unittest

import numpy as np

from recognition.stream import fusion, temporal
from recognition.stream.context import Candidate, JevResolver, NoContext, UNKNOWN
from recognition.stream.provider import RecognitionProvider, Window
from recognition.stream.temporal import ResolverConfig, TemporalResolver, make_windows

GLOSSES = ["water", "drink", "coffee", "tea"]


class Stub(RecognitionProvider):
    """TEST DOUBLE ONLY. Reports a fixed distribution after a fixed delay."""
    def __init__(self, name, dist, delay=0.0):
        self.name, self.labels, self.dist, self.delay = name, GLOSSES, np.asarray(dist, float), delay

    def probs(self, windows, vocab):
        time.sleep(self.delay)
        return np.tile(self.dist / self.dist.sum(), (len(windows), 1))

    def info(self):
        return {}


class WindowTests(unittest.TestCase):
    def test_last_window_reaches_stream_end_and_overlaps(self):
        w = make_windows(2.3, 1.0, 0.25)
        self.assertEqual(w[0], (0.0, 1.0))
        self.assertAlmostEqual(w[-1][1], 2.3)
        self.assertTrue(all(b[0] < a[1] for a, b in zip(w, w[1:])))     # overlapping

    def test_short_stream_is_one_window(self):
        self.assertEqual(make_windows(0.6, 1.0, 0.25), [(0.0, 0.6)])


class ResolverTests(unittest.TestCase):
    def seq(self, rows):
        r = TemporalResolver(ResolverConfig())
        return [r.step(np.array(x)) for x in rows]

    def test_rising_evidence_progresses_and_can_be_revised(self):
        rise = [[.34, .31, .12, .23], [.57, .23, .08, .12], [.81, .10, .03, .06], [.92, .04, .01, .03], [.95, .03, .01, .01]]
        states = [s["state"] for s in self.seq(rise)]
        self.assertEqual(states[0], "tentative")
        self.assertIn("committed", states)
        self.assertEqual(states.index("committed") > states.index("stable") or "stable" not in states, True)
        # a later window with different evidence must pull the display back down
        r = TemporalResolver(ResolverConfig())
        for x in rise:
            r.step(np.array(x))
        for _ in range(4):
            last = r.step(np.array([.05, .85, .05, .05]))
        self.assertEqual(last["top"][0][0], 1)
        self.assertNotEqual(self.seq(rise)[-1]["top"][0][0], last["top"][0][0])

    def test_high_uncertainty_is_unknown_not_forced(self):
        states = [s["state"] for s in self.seq([[.26, .25, .25, .24]] * 4)]
        self.assertNotIn("committed", states)
        self.assertNotIn("stable", states)

    def test_flat_low_evidence_is_unknown(self):
        cfg = ResolverConfig(tau_u=0.3)
        self.assertEqual(TemporalResolver(cfg).step(np.array([.26, .25, .25, .24]))["state"], "unknown")


class FusionTests(unittest.TestCase):
    def test_geo_and_mean_normalize_and_majority_breaks_ties_by_probability(self):
        a, b, c = np.array([.6, .3, .1]), np.array([.2, .5, .3]), np.array([.55, .35, .1])
        self.assertAlmostEqual(fusion.geo_mean([a, b, c]).sum(), 1.0)
        self.assertAlmostEqual(fusion.mean_prob([a, b, c]).sum(), 1.0)
        self.assertEqual(int(fusion.majority_vote([a, b, c]).argmax()), 0)            # two votes for class 0
        self.assertEqual(int(fusion.majority_vote([a, b]).argmax()), 0)               # 1-1 tie -> higher mean prob


class ContextContractTests(unittest.TestCase):
    def test_parse_rejects_invented_labels_and_bad_probabilities(self):
        good = {"system_one": {"answers": {"sign": {"type": "choice", "probabilities": {"water": .6, "drink": .3, UNKNOWN: .1}}}}}
        self.assertEqual(JevResolver._parse(good, {"water", "drink"})["water"], .6)
        invented = {"system_one": {"answers": {"sign": {"type": "choice", "probabilities": {"water": .6, "juice": .3, UNKNOWN: .1}}}}}
        with self.assertRaises(ValueError):
            JevResolver._parse(invented, {"water", "drink"})
        bad = {"system_one": {"answers": {"sign": {"type": "choice", "probabilities": {"water": .9, "drink": .9, UNKNOWN: .9}}}}}
        with self.assertRaises(ValueError):
            JevResolver._parse(bad, {"water", "drink"})

    def test_failed_resolver_reports_failure_instead_of_guessing(self):
        class Broken:
            def message(self, *a, **k):
                raise RuntimeError("network down")
        d = JevResolver(gateway=Broken()).resolve(["i"], [Candidate("water", .5), Candidate("drink", .4)])
        self.assertFalse(d.ok)
        self.assertEqual(d.resolved, UNKNOWN)

    def test_no_context_is_visual_top1(self):
        d = NoContext().resolve([], [Candidate("drink", .4), Candidate("water", .5)])
        self.assertEqual(d.resolved, "water")


# Session lifecycle and concurrency regressions live in test_controller.py.


if __name__ == "__main__":
    unittest.main()
