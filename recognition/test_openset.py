import copy
import unittest

import numpy as np

from recognition import data as D
from recognition import synthetic as S
from recognition.metrics import auroc, classification_report, ece, fit_temperature, softmax, wilson_upper
from recognition.openset import Policy, decide, derive_policy, scores


def fake_logits(n_known=3, n=200, seed=0, sep=6.0):
    rng = np.random.default_rng(seed)
    y = rng.integers(0, n_known + 1, n)
    z = rng.normal(0, 1, (n, n_known + 1))
    z[np.arange(n), y] += sep
    return z, y


class ScoreTests(unittest.TestCase):
    def test_log_odds_does_not_saturate(self):
        z = np.array([[60.0, 0, 0, 0], [80.0, 0, 0, 0]])
        p = scores("max_prob", z)
        lo = scores("log_odds", z)
        self.assertEqual(p[0], p[1])           # probability space ties at 1.0
        self.assertGreater(lo[1], lo[0])       # log-odds keeps the ordering

    def test_unknown_logit_lowers_score(self):
        known = np.array([[5.0, 0, 0, 0]])
        unknown = np.array([[5.0, 0, 0, 6.0]])
        for name in ("log_odds", "max_prob", "margin"):
            self.assertGreater(scores(name, known)[0], scores(name, unknown)[0], name)

    def test_auroc_reference_values(self):
        self.assertEqual(auroc([3, 4], [1, 2]), 1.0)
        self.assertEqual(auroc([1, 2], [3, 4]), 0.0)
        self.assertEqual(auroc([1, 1], [1, 1]), 0.5)


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.known = ["A", "B", "C"]

    def test_tiny_validation_set_cannot_show(self):
        z, y = fake_logits(n=30)
        p = derive_policy("log_odds", z, y, np.ones(30), self.known, 1.0, far_high=0.05)
        self.assertEqual(p.tau_high, float("inf"))
        self.assertFalse(p.can_show)
        self.assertGreaterEqual(p.min_reference_n, 73)
        for label, tier, _ in decide(p, z[:5], np.ones(5)):
            self.assertNotEqual(tier, "show")

    def test_thresholds_bound_validation_false_accepts(self):
        z, y = fake_logits(n=800, sep=5.0)
        q = np.ones(800)
        p = derive_policy("log_odds", z, y, q, self.known, 1.0, far_high=0.10, far_low=0.30)
        dec = decide(p, z, q)
        shown_unknown = sum(1 for (i, t, _), yy in zip(dec, y) if t == "show" and yy == 3)
        self.assertLessEqual(shown_unknown / (y == 3).sum(), 0.10)
        self.assertLessEqual(p.tau_low, p.tau_high)

    def test_tiers_and_low_tracking_gate(self):
        p = Policy("log_odds", 1.0, tau_high=4.0, tau_low=1.0, quality_min=0.5, known=self.known,
                   target_far_high=0.05, target_far_low=0.2)
        base = np.array([[6.0, 0, 0, 0], [2.5, 0, 0, 0], [0.5, 0.4, 0.3, 0], [1.0, 0, 0, 9.0]])
        tiers = [t for _, t, _ in decide(p, base, np.ones(4))]
        self.assertEqual(tiers[0], "show")
        self.assertEqual(tiers[1], "retry")
        self.assertEqual(tiers[2], "unknown")
        self.assertEqual(tiers[3], "unknown")           # background wins argmax
        gated = decide(p, base[:1], np.array([0.2]))
        self.assertEqual(gated[0][1], "low_tracking")
        self.assertEqual(gated[0][0], 3)                # never a supported label

    def test_never_promotes_unknown_to_a_label(self):
        p = Policy("log_odds", 1.0, -1e9, -1e9, 0.0, self.known, 0.05, 0.2)   # accept-everything thresholds
        for idx, tier, _ in decide(p, np.array([[0, 0, 0, 5.0]]), np.ones(1)):
            self.assertEqual(idx, 3)


class CalibrationTests(unittest.TestCase):
    def test_ece_perfect_and_overconfident(self):
        rng = np.random.default_rng(0)
        conf = rng.uniform(0.5, 1, 5000)
        correct = rng.random(5000) < conf
        self.assertLess(ece(conf, correct), 0.03)
        self.assertGreater(ece(np.full(1000, 0.99), rng.random(1000) < 0.6), 0.3)

    def test_temperature_scaling_reduces_overconfidence(self):
        rng = np.random.default_rng(0)
        y = rng.integers(0, 4, 3000)
        z = rng.normal(0, 3, (3000, 4))
        z[np.arange(3000), y] += 2.0     # ~ moderately informative logits, scaled up: overconfident
        z *= 3
        T = fit_temperature(z, y)
        self.assertGreater(T, 1.5)
        acc = z.argmax(1) == y
        self.assertLess(ece(softmax(z, T).max(1), acc), ece(softmax(z, 1).max(1), acc))

    def test_wilson_bound(self):
        self.assertAlmostEqual(wilson_upper(0, 73), 3.8416 / (73 + 3.8416), places=3)
        self.assertGreater(wilson_upper(1, 50), 1 / 50)

    def test_report_macro_metrics_ignore_absent_classes(self):
        r = classification_report([0, 0, 1, 1], [0, 0, 1, 0], ["a", "b", "c", "UNKNOWN"])
        self.assertAlmostEqual(r["accuracy"], 0.75)
        self.assertFalse(np.isnan(r["macro_f1"]))


class DataIntegrityTests(unittest.TestCase):
    def corpus(self):
        return S.make_corpus(n_signers=6, per_class=1, per_neg=1, seed=1)["samples"]

    def test_signer_split_is_disjoint_and_deterministic(self):
        a, b = self.corpus(), self.corpus()
        D.assign_splits(a, 0)
        D.assign_splits(b, 0)
        self.assertEqual([s["split"] for s in a], [s["split"] for s in b])
        D.assert_no_leakage(a)
        by = {}
        for s in a:
            by.setdefault(s["signer"], set()).add(s["split"])
        self.assertTrue(all(len(v) == 1 for v in by.values()))
        self.assertEqual({s["split"] for s in a}, {"train", "val", "test"})

    def test_leakage_detected(self):
        s = self.corpus()
        D.assign_splits(s, 0)
        leaky = copy.deepcopy(s)
        victim = next(x for x in leaky if x["split"] == "test")
        victim["split"] = "train"
        with self.assertRaises(D.CorpusError):
            D.assert_no_leakage(leaky)      # same signer now in two splits
        dup = copy.deepcopy(s)
        a = next(x for x in dup if x["split"] == "train" and x["label"] != "UNKNOWN")
        b = next(x for x in dup if x["split"] == "test" and x["label"] != "UNKNOWN")
        b["frames"] = copy.deepcopy(a["frames"])
        with self.assertRaises(D.CorpusError):
            D.assert_no_leakage(dup)         # identical geometry across splits

    def test_folds_never_share_signers(self):
        s = self.corpus()
        for fold in D.signer_folds(s, 3, seed=0):
            D.apply_fold(s, fold)
            D.assert_no_leakage(s)
            self.assertTrue(fold["test"] and fold["train"] and fold["val"])
        with self.assertRaises(D.CorpusError):
            D.assign_splits(s[:1], 0)   # one signer cannot be split by signer

    def test_unlicensed_training_data_is_not_shippable(self):
        s = self.corpus()
        D.assign_splits(s, 0)
        D.assert_shippable(s)               # synthetic: ALLOWED
        s[0]["split"] = "train"
        s[0]["redistribution"] = "PROHIBITED"
        with self.assertRaises(D.CorpusError):
            D.assert_shippable(s)


if __name__ == "__main__":
    unittest.main()
