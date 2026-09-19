"""Scheduling/filter tests; synthetic markers are not ASL examples."""
import unittest

from .stream_replay import DisplayFilter, replay_clip, summarize


def frames(count=41):
    return [{"timestampMS": i*100, "hands": [True]} for i in range(count)]


def decision(label):
    return {"unknown": label is None, "candidates": [{"label": label}] if label else []}


class Tests(unittest.TestCase):
    def test_filter(self):
        f = DisplayFilter()
        self.assertIsNone(f.update("YES"))
        self.assertEqual(f.update("YES"), "YES")
        self.assertIsNone(f.update("NO"))
        self.assertIsNone(f.update(None))
        self.assertIsNone(f.update("NO"))
        self.assertEqual(f.update("NO"), "NO")
        f.reset()
        self.assertIsNone(f.update("NO"))

    def test_causal_windows_and_no_invented_tail(self):
        received = []
        def classify(window):
            received.append([f["timestampMS"] for f in window])
            return decision("YES")
        run = replay_clip(frames(), classify)
        self.assertEqual([w[-1] for w in received], [0, 1000, 2000, 3000, 4000])
        self.assertEqual(received[2], list(range(800, 2001, 100)))
        self.assertEqual(run["onsets"], [{"label": "YES", "t_ms": 1000}])
        self.assertEqual(run["requests"], 5)

    def test_no_hands_between_requests_resets(self):
        data = frames(21)
        data[5]["hands"] = []
        run = replay_clip(data, lambda _: decision("YES"))
        self.assertEqual(run["onsets"], [{"label": "YES", "t_ms": 2000}])
        self.assertTrue(any(e["reset"] for e in run["events"]))

    def test_unknown_clears_and_reappearance_counted(self):
        labels = iter(["YES", "YES", None, "YES", "YES"])
        run = replay_clip(frames(), lambda _: decision(next(labels)))
        self.assertEqual([e["t_ms"] for e in run["onsets"]], [1000, 4000])
        summary = summarize([{"truth": "YES", **run}])
        self.assertEqual(summary["repeated_same_label_runs"], 1)
        self.assertEqual(summary["correct_visible_runs"], 1)
        self.assertEqual(summary["wrong_visible_runs"], 0)

    def test_phase_sensitivity_and_short_sign(self):
        def classify(window):
            return decision("YES" if 300 <= window[-1]["timestampMS"] <= 1400 else None)
        a = replay_clip(frames(), classify)
        b = replay_clip(frames(), classify, phase_ms=333)
        self.assertEqual(a["onsets"], [])
        self.assertEqual(b["onsets"], [{"label": "YES", "t_ms": 1400}])

    def test_unknown_false_accepts_and_wrong_known_labels_count(self):
        run = replay_clip(frames(), lambda _: decision("YES"))
        result = summarize([{"truth": "UNKNOWN", **run}, {"truth": "NO", **run}])
        self.assertEqual(result["wrong_visible_runs"], 2)
        self.assertEqual(result["correct_visible_runs"], 0)

    def test_empty_invalid_and_no_hand_polling(self):
        self.assertEqual(replay_clip([], None)["requests"], 0)
        for kwargs in ({"window_ms": 0}, {"interval_ms": 0}, {"phase_ms": 1000}):
            with self.assertRaises(ValueError):
                replay_clip(frames(), None, **kwargs)
        with self.assertRaises(ValueError):
            replay_clip(list(reversed(frames())), None)
        data = frames(5)
        data[0]["hands"] = []
        run = replay_clip(data, lambda _: decision("YES"))
        self.assertEqual(run["events"][1]["t_ms"], 200)


if __name__ == "__main__":
    unittest.main()
