"""Synthetic local-gesture policy checks; not recognition accuracy evidence."""
import unittest

from .research_static import accepted, filter_frames


def frame(t, label="ILoveYou", count=1):
    return {"timestampMS": t, "hands": [
        {"label": label, "score": .95, "runner": .03} for _ in range(count)]}


class Tests(unittest.TestCase):
    def test_only_ily_mapping(self):
        for label in ("Thumb_Up", "Thumb_Down", "Closed_Fist", "Open_Palm", "Victory", "None", "YES"):
            self.assertFalse(accepted(label, .99, .01))
        self.assertTrue(accepted("ILoveYou", .95, .03))

    def test_invalid_weak_ambiguous_scores(self):
        for score, runner in ((float("nan"), 0), (1.1, 0), (.9, -.1), (.8, .05), (.9, .75)):
            self.assertFalse(accepted("ILoveYou", score, runner))

    def test_hold_clear_and_multiple_hands(self):
        data = [frame(0), frame(75), frame(150), frame(180, count=0), frame(225, count=2)]
        self.assertEqual(filter_frames(data), [False, False, True, False, False])

    def test_gap_and_reversed_time(self):
        data = [frame(0), frame(75), frame(400), frame(399), frame(-1), frame(150)]
        self.assertEqual(filter_frames(data), [False]*6)


if __name__ == "__main__":
    unittest.main()
