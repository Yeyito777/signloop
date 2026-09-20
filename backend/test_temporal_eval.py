import unittest
from .temporal_eval import summarize


class TemporalEvaluationTests(unittest.TestCase):
    def test_empty(self):
        self.assertEqual(summarize([])["majority_correct"], 0)
        self.assertEqual(summarize([])["mean_clip_window_correct"], 0)

    def test_missing_evidence_stays_in_denominator(self):
        result = summarize([
            dict(label="MY", events=[dict(label="MY"), dict(label="PLEASE")], elapsedMS=2),
            dict(label="YOU", events=[dict(label=None)], elapsedMS=3),
            dict(label="UNSUPPORTED", events=[dict(label="MY")], elapsedMS=4),
        ])
        self.assertEqual(result["supported"], 2)
        self.assertEqual(result["with_guess"], 1)
        # Ties use first occurrence, consistently; this is a plurality metric.
        self.assertEqual(result["majority_correct"], 1)
        self.assertEqual(result["mean_clip_window_correct"], .25)
        self.assertEqual(result["unsupported_with_guess"], 1)
        self.assertEqual(result["scheduled_events"], 4)
        self.assertEqual(result["replay_ms"], 9)


if __name__ == "__main__":
    unittest.main()
