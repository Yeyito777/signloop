import copy
import unittest
from .score_audit import compare


class ScoreAuditTests(unittest.TestCase):
    def fixture(self):
        return [dict(id="synthetic", events=[
            dict(timestamp=0),
            dict(timestamp=100, label="A", scores=[
                dict(label="A", distance=0.1), dict(label="B", distance=0.2)]),
        ])]

    def test_competition_without_dilution(self):
        a = self.fixture()
        b = copy.deepcopy(a)
        b[0]["events"][1]["label"] = "C"
        b[0]["events"][1]["scores"].append(dict(label="C", distance=0.05))
        self.assertEqual(compare(a, b, ["A", "B"]),
                         dict(identical_original_scores=2, measured_events=1, winner_changes=1))

    def test_detects_dilution_and_schedule_changes(self):
        a = self.fixture()
        for mutation in ("score", "schedule", "availability", "id", "length"):
            b = copy.deepcopy(a)
            if mutation == "score":
                b[0]["events"][1]["scores"][0]["distance"] = 0.10001
            elif mutation == "schedule":
                b[0]["events"][1]["timestamp"] = 101
            elif mutation == "availability":
                b[0]["events"][0]["scores"] = []
            elif mutation == "id":
                b[0]["id"] = "other"
            else:
                b[0]["events"].pop()
            with self.subTest(mutation=mutation), self.assertRaises(AssertionError):
                compare(a, b, ["A", "B"])
