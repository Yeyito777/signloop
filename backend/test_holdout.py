"""Metadata selection and pacing mechanics; no images or model calls."""
import unittest
import tempfile
from pathlib import Path
from .research_holdout import select, identifier, Cadence
from .research_confirmation import calibration_samples


def row(name, signer, gloss):
    return {"Video file": name, "Participant ID": signer, "Gloss": gloss}


class Tests(unittest.TestCase):
    def test_confirmation_calibration_refuses_unpinned_cohort(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/"test.json"
            path.write_text('{"samples": [{"split": "calibration"}]}')
            with self.assertRaisesRegex(ValueError, "original, pinned"):
                calibration_samples(path)

    def test_old_clips_excluded_but_known_signer_positive_disclosed(self):
        rows = [row("seen", "A", "HELLO"), row("new", "A", "YES"),
                row("oldperson-negative", "A", "CAT"), row("newperson-negative", "B", "DOG")]
        selected = select(rows, {identifier(rows[0])})
        self.assertEqual(len(selected), 2)
        positive = next(s for s in selected if s["label"] == "YES")
        self.assertFalse(positive["new_signer"])
        self.assertEqual(next(s for s in selected if s["label"] == "UNKNOWN")["row"]["Participant ID"], "B")

    def test_ily_is_supported_never_negative(self):
        selected = select([row("ily", "A", "ILOVEYOU")], set())
        self.assertEqual(selected[0]["label"], "I_LOVE_YOU")
        self.assertTrue(selected[0]["new_signer"])

    def test_per_signer_cap_global_gloss_diversity_and_order_independence(self):
        rows = [row(str(i), str(i%3), "OTHER"+str(i)) for i in range(30)]
        selected = select(rows, set())
        self.assertEqual(selected, select(rows[::-1], set()))
        self.assertEqual(len(selected), 9)
        self.assertEqual(len({s["row"]["Gloss"] for s in selected}), 9)
        for signer in ("0", "1", "2"):
            self.assertEqual(sum(s["row"]["Participant ID"] == signer for s in selected), 3)

    def test_supported_clips_not_capped_or_cherry_picked(self):
        rows = [row(str(i), "same", "NO") for i in range(20)]
        self.assertEqual(len(select(rows, set())), 20)

    def test_duplicate_gloss_not_counted_as_diverse_negative(self):
        rows = [row(str(i), str(i), "CAT") for i in range(10)]
        self.assertEqual(len(select(rows, set())), 1)

    def test_pacing_matches_native_regular_stream_contract(self):
        for fps in (10, 15, 24, 30, 60, 120):
            gate = Cadence()
            count = sum(gate.admit(100+i/fps) for i in range(60*fps))
            self.assertLessEqual(abs(count-min(fps, 24)*60), 1)
        gate = Cadence()
        self.assertTrue(gate.admit(0))
        self.assertTrue(gate.admit(30))
        self.assertFalse(gate.admit(30.001))


if __name__ == "__main__":
    unittest.main()
