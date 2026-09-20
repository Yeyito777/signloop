import unittest
from unittest.mock import patch

from . import basic_signs as data
from .basic_corpus import validate_arrays


class BasicSignsTests(unittest.TestCase):
    def splits(self):
        splits = {}
        for split, count in data.LIMITS.items():
            rows = []
            for label in data.LABELS:
                for i in range(count+1):
                    rows.append({"Participant ID": split+str(i), "Gloss": label,
                                 "Video file": f"{split}-{label}-{i}.mp4"})
            for i in range(12):
                rows.append({"Participant ID": split+"0", "Gloss": f"UNSUPPORTED{i}",
                             "Video file": f"{split}-negative-{i}.mp4"})
            splits[split] = rows
        return splits

    def test_small_balanced_temporal_plan(self):
        planned = data.select(self.splits())
        self.assertEqual(len(planned), 196)
        self.assertEqual(len({r["id"] for r in planned}), 196)
        for split, expected in data.LIMITS.items():
            for label in data.LABELS:
                rows = [s for s in planned if s["split"] == split and s["label"] == label]
                self.assertEqual(len(rows), expected)
                self.assertEqual(len({r["signer"] for r in rows}), expected)
        self.assertFalse(any(r["split"] == "train" and r["label"] == "UNKNOWN" for r in planned))
        self.assertEqual(sum(r["label"] == "UNKNOWN" for r in planned), 20)

    def test_selection_does_not_depend_on_metadata_order(self):
        splits = self.splits()
        expected = data.select(splits)
        self.assertEqual(expected, data.select({s: list(reversed(r)) for s, r in splits.items()}))

    def test_demo32_retains_original_training_and_adds_human_examples(self):
        splits = self.splits()
        for split, count in data.LIMITS.items():
            for label in data.DEMO_LABELS[len(data.LABELS):]:
                for i in range(count+1):
                    splits[split].append({"Participant ID": split+str(i), "Gloss": label,
                                         "Video file": f"{split}-{label}-{i}.mp4"})
        old = data.select(splits)
        new = data.select(splits, data.DEMO_LABELS)
        self.assertEqual(len(new), 372)
        self.assertEqual(len(data.DEMO_LABELS), 32)
        self.assertIn("ILOVEYOU", data.DEMO_LABELS)
        self.assertEqual([x for x in old if x["split"] == "train"],
                         [x for x in new if x["split"] == "train" and x["label"] in data.LABELS])
        self.assertEqual(sum(x["label"] == "ILOVEYOU" for x in new), 11)

    def test_no_signer_leakage_or_silent_missing_sign(self):
        splits = self.splits()
        splits["test"][0]["Participant ID"] = splits["train"][0]["Participant ID"]
        with self.assertRaisesRegex(ValueError, "Signer leakage"):
            data.select(splits)
        splits = self.splits()
        splits["train"] = [r for r in splits["train"] if r["Gloss"] != "HELLO"]
        with self.assertRaisesRegex(ValueError, "Not enough"):
            data.select(splits)

    def test_archive_names_cannot_escape(self):
        for filename in ("../foo.mp4", "/foo.mp4", "folder/file.mp4", "folder\\file.mp4"):
            with self.assertRaisesRegex(ValueError, "Unsafe"):
                data.sample({"Video file": filename, "Gloss": "HELLO", "Participant ID": "A"}, "train", "HELLO")

    def test_download_budget_blocks_before_network_read(self):
        with patch.object(data.RangeReader, "__init__", return_value=None):
            reader = data.BudgetReader()
        reader.size, reader.position = 1000, 0
        with patch.object(data.RangeReader, "read", return_value=b"123") as read:
            self.assertEqual(reader.read(3), b"123")
            self.assertEqual(reader.bytes_read, 3)
            reader.bytes_read = data.MAX_DOWNLOAD-2
            with self.assertRaisesRegex(ValueError, "budget"):
                reader.read(3)
            self.assertEqual(read.call_count, 1)

    def test_transient_range_retry_is_bounded_and_charged(self):
        import http.client
        with patch.object(data.RangeReader, "__init__", return_value=None):
            reader = data.BudgetReader()
        reader.size, reader.position = 1000, 0
        with patch.object(data.RangeReader, "read", side_effect=[http.client.RemoteDisconnected(), b"123"]), \
             patch.object(data.time, "sleep"):
            self.assertEqual(reader.read(3), b"123")
        self.assertEqual(reader.bytes_read, 6)
        with patch.object(data.RangeReader, "read", side_effect=ValueError("Server ignored range")) as read:
            with self.assertRaises(ValueError):
                reader.read(3)
            self.assertEqual(read.call_count, 1)

    def test_same_wrist_assignment_rules_as_swift(self):
        try:
            import numpy as np
        except ImportError:
            self.skipTest("Optional research NumPy")
        pose = np.zeros((25, 3))
        pose[15, :2], pose[16, :2] = [.2, .5], [.8, .5]
        valid = np.ones(25, bool)
        hand = lambda x, y: np.tile([x, y, 0.], (21, 1))
        a, b = hand(.21, .5), hand(.79, .5)
        self.assertEqual(data.hand_sides([a, b], pose, valid, 1), [0, 1])
        self.assertEqual(data.hand_sides([b, a], pose, valid, 1), [1, 0])
        self.assertEqual(data.hand_sides([hand(.5, .5)], pose, valid, 1), [-1])
        self.assertEqual(data.hand_sides([hand(.1, .1)], pose, valid, 1), [-1])
        self.assertEqual(data.hand_sides([a, hand(.8, .01)], pose, valid, 1), [0, -1])
        valid[15] = False
        self.assertEqual(data.hand_sides([a], pose, valid, 1), [-1])
        self.assertEqual(data.hand_sides([], pose, valid, 1), [])

    def test_compact_schema_rejects_stale_and_malformed_features(self):
        try:
            import numpy as np
        except ImportError:
            self.skipTest("Optional research NumPy")
        a = {"timestamp_ms": np.array([0, 67, 133]), "hands": np.zeros((3, 2, 21, 3)),
             "hand_valid": np.zeros((3, 2), bool), "hand_sides": np.full((3, 2), -1),
             "pose": np.zeros((3, 25, 3)), "pose_valid": np.zeros((3, 25), bool),
             "pose_confidence": np.zeros((3, 25, 2)), "face_anchors": np.zeros((3, len(data.FACE_IDS), 3)),
             "face_valid": np.zeros(3, bool), "face_ids": np.array(data.FACE_IDS),
             "blendshape_names": np.array([], dtype="U32"), "blendshapes": np.zeros((3, 0)),
             "width": np.array(720), "height": np.array(1280), "source_fps": np.array(30.)}
        validate_arrays(a)
        for name, value in (("timestamp_ms", np.array([0, 67, 67])),
                            ("hands", np.full((3, 2, 21, 3), np.nan)),
                            ("hand_sides", np.zeros((3, 2))),
                            ("face_valid", np.ones(3, bool)),
                            ("width", np.array(0)),
                            ("pose", np.zeros((3, 33, 3)))):
            with self.assertRaises(ValueError, msg=name):
                validate_arrays(a | {name: value})


if __name__ == "__main__":
    unittest.main()
