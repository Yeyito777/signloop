"""Geometric association tests, not ASL accuracy evidence."""
import copy
import unittest

from .hand_tracking import stabilize
from .matcher import TrackedReferenceMatcher, features, dtw
from .test_matcher import geometry


def two_hands():
    data = geometry()
    for f in data:
        left = copy.deepcopy(f["hands"][0])
        left["handedness"] = "Left"
        for joint in left["joints"]:
            joint["x"] -= .25
        f["hands"].append(left)
    return data


class Tests(unittest.TestCase):
    def test_transient_label_error_keeps_wrist_identity(self):
        data = two_hands()
        expected = features(data)
        data[5]["hands"][1]["handedness"] = "Right"
        diagnostics = {}
        result = TrackedReferenceMatcher.feature_function(data, diagnostics)
        self.assertAlmostEqual(dtw(expected, result), 0.)
        self.assertGreater(diagnostics["hand_labels_reassociated"], 0)

    def test_detection_order_is_not_identity(self):
        original = two_hands()
        reordered = copy.deepcopy(original)
        for i, frame in enumerate(reordered):
            if i % 2:
                frame["hands"].reverse()
        a = TrackedReferenceMatcher.feature_function(original)
        b = TrackedReferenceMatcher.feature_function(reordered)
        self.assertAlmostEqual(dtw(a, b), 0)

    def test_single_hand_label_flips(self):
        original, noisy = geometry(), geometry()
        for frame in noisy[4:7]:
            frame["hands"][0]["handedness"] = "Left"
        self.assertAlmostEqual(dtw(features(original), TrackedReferenceMatcher.feature_function(noisy)), 0)

    def test_duplicate_physical_detection_is_removed(self):
        original, duplicate = geometry(), geometry()
        for frame in duplicate:
            ghost = copy.deepcopy(frame["hands"][0])
            ghost["handedness"] = "Left"
            ghost["handednessScore"] = .2
            frame["hands"].append(ghost)
        diagnostics = {}
        actual = TrackedReferenceMatcher.feature_function(duplicate, diagnostics)
        self.assertAlmostEqual(dtw(features(original), actual), 0)
        self.assertEqual(diagnostics["duplicate_detections_removed"], len(duplicate))

    def test_missing_hands_are_not_fabricated(self):
        frames = geometry()
        frames[6]["hands"] = []
        frames[7]["hands"] = []
        result = stabilize(frames)
        self.assertFalse(result[6]["hands"])
        self.assertFalse(result[7]["hands"])
        self.assertEqual(result[8]["hands"][0]["handedness"], "Right")

    def test_ambiguous_initial_pair_is_not_arbitrarily_assigned(self):
        frames = two_hands()
        for f in frames:
            for h in f["hands"]:
                h["handedness"] = "Right"
                h["handednessScore"] = .5
        diagnostics = {}
        result = TrackedReferenceMatcher.feature_function(frames, diagnostics)
        self.assertFalse(result)
        self.assertEqual(diagnostics["ambiguous_assignment_frames"], len(frames))

    def test_large_gap_discards_stale_identity(self):
        frames = geometry()
        # A different hand appears after a long unobserved interval.
        frames[8]["timestampMS"] = frames[7]["timestampMS"] + 400
        for i in range(9, len(frames)):
            frames[i]["timestampMS"] = frames[i-1]["timestampMS"] + 80
        for f in frames[8:]:
            f["hands"][0]["handedness"] = "Left"
        result = stabilize(frames)
        self.assertEqual(result[8]["hands"][0]["handedness"], "Left")

    def test_fresh_holdout_excludes_previously_used_signers(self):
        # Selection isolation, without downloading any data.
        from .research_data import fresh_signer_rows, select_rows
        labels = ("HELLO", "YES", "NO", "PLEASE", "THANKYOU", "OTHER")
        splits = {}
        for split, size in (("train", 35), ("val", 4), ("test", 12)):
            splits[split] = [{"Participant ID": f"{split}-{i}", "Gloss": label,
                              "Video file": f"{split}-{i}-{label}.mp4"}
                             for i in range(size) for label in labels]
        original = select_rows(splits, 6, 15)
        used = {row["Participant ID"] for _, _, row in original}
        fresh = fresh_signer_rows(splits, 6, 15)
        heldout = {row["Participant ID"] for split, _, row in fresh if split == "test"}
        self.assertTrue(heldout)
        self.assertFalse(used & heldout)


if __name__ == "__main__":
    unittest.main()
