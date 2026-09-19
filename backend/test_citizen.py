import csv
import hashlib
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from . import research_citizen as citizen
from . import research_citizen_stream as streaming
from .research_citizen_hybrid import associate


class CitizenTests(unittest.TestCase):
    def test_hybrid_association_preserves_body_and_hand_identity(self):
        try:
            import numpy as np
        except ImportError:
            self.skipTest("Optional NumPy")
        pose = np.zeros((75, 2))
        pose[15], pose[16] = [.8, .5], [.2, .5]
        right = np.tile([.21, .5], (21, 1))
        left = np.tile([.79, .5], (21, 1))
        a = associate(pose, [right, left])
        b = associate(pose, [left, right])
        np.testing.assert_array_equal(a, b)
        np.testing.assert_array_equal(a[:33], pose[:33])
        np.testing.assert_array_equal(a[33:54], right)
        np.testing.assert_array_equal(a[54:], left)
        self.assertFalse(associate(pose, []) [33:].any())
        self.assertFalse(associate(pose, [np.tile([.5, .5], (21, 1))])[33:].any())
        self.assertFalse(associate(pose, [np.tile([3., 3.], (21, 1))])[33:].any())
        self.assertFalse(pose[33:].any(), "Source array was modified")

    def test_stream_confirmation_and_missing_hand_reset(self):
        event = {"valid": True, "ranked": [{"label": "HELLO", "score": .9},
                                          {"label": "DOG", "score": .05}]}
        rows = [{"gloss": "HELLO", "events": [event, {"valid": False}, event]}]
        counts = streaming.summarize(rows, .4, .05)["counts"]
        self.assertEqual(counts["supported_raw_correct"], 1)
        self.assertEqual(counts["supported_correct_visible"], 0)
        rows[0]["events"].append(event)
        self.assertEqual(streaming.summarize(rows, .4, .05)["counts"]["supported_correct_visible"], 1)

    def test_stream_calibration_counts_wrong_supported_and_unsupported(self):
        def events(label, score):
            return [{"valid": True, "ranked": [{"label": label, "score": score},
                                               {"label": "DOG", "score": .01}]}]*2
        rows = [{"gloss": "HELLO", "events": events("HELLO", .9)},
                {"gloss": "YES", "events": events("HELLO", .7)},
                {"gloss": "DOG", "events": events("HELLO", .6)}]
        parameters = streaming.calibrate(rows)
        counts = streaming.summarize(rows, *parameters)["counts"]
        self.assertEqual(counts["supported_correct_visible"], 1)
        self.assertEqual(counts["any_wrong_visible"], 0)

    def test_rejection_competes_with_all_classes(self):
        self.assertIsNone(citizen.accepted([{"label": "DOG", "score": .99},
                                          {"label": "HELLO", "score": .01}], .4, .05))
        self.assertIsNone(citizen.accepted([{"label": "HELLO", "score": .4},
                                          {"label": "YES", "score": .01}], .4, .05))
        self.assertIsNone(citizen.accepted([{"label": "HELLO", "score": .8},
                                          {"label": "YES", "score": .79}], .4, .05))

    def test_calibration_rejects_wrong_known_and_negative(self):
        rows = [{"gloss": truth, "ranked": [{"label": label, "score": score},
                                           {"label": "DOG", "score": .01}]}
                for truth, label, score in [("HELLO", "HELLO", .9),
                                            ("YES", "HELLO", .7),
                                            ("DOG", "YES", .6)]]
        parameters = citizen.calibrate(rows)
        counts = citizen.summarize(rows, *parameters)["counts"]
        self.assertEqual(counts["correct_accepted"], 1)
        self.assertEqual(counts["wrong_accepted"], 0)
        self.assertEqual(counts["unsupported_false_accept"], 0)

    def test_plan_excludes_official_train_and_rejects_split_leakage(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            clips = root/"clips"
            clips.mkdir()
            hashes = {}
            for split, signer in [("train", "A"), ("val", "B"), ("test", "C")]:
                rows = [(signer, split+".mp4", "HELLO")]
                if split == "train":
                    rows += [(signer, f"unused{i}.mp4", f"Z{i:04}") for i in range(2730)]
                path = root/(split+".csv")
                with path.open("w") as stream:
                    writer = csv.writer(stream)
                    writer.writerow(["Participant ID", "Video file", "Gloss"])
                    writer.writerows(rows)
                hashes[split] = citizen.sha(path)
                (clips/(hashlib.sha256((split+".mp4").encode()).hexdigest()+".mp4")).write_bytes(b"local")
            with patch.object(citizen, "METADATA", hashes):
                result = citizen.plan(root, [clips])
                self.assertEqual([s["split"] for s in result["samples"]], ["val", "test"])
                self.assertEqual(len(result["vocabulary"]), 2731)
                path = root/"test.csv"
                path.write_text(path.read_text().replace("C,test", "A,test"))
                hashes["test"] = citizen.sha(path)
                with self.assertRaisesRegex(ValueError, "participant disjoint"):
                    citizen.plan(root, [clips])

    def test_pose_shape_and_zero_missing_landmarks(self):
        try:
            import numpy as np
        except ImportError:
            self.skipTest("Optional NumPy")
        zeros = np.zeros((10, 75, 2))
        output = citizen.pose_tensor(zeros)
        self.assertEqual(output.shape, (2, 128, 27))
        self.assertTrue((output == 0).all())
        with self.assertRaises(ValueError):
            citizen.pose_tensor(np.zeros((0, 75, 2)))
        with self.assertRaises(ValueError):
            citizen.pose_tensor(np.full((10, 75, 2), np.nan))
        sequence = np.arange(300)[:, None]
        selected = citizen.downsample(sequence)
        self.assertEqual(len(selected), 128)
        self.assertTrue((np.diff(selected[:, 0]) > 0).all())

    def test_pose_adapter_matches_original_dataset(self):
        root = os.environ.get("SIGNLOOP_CITIZEN_UPSTREAM")
        if not root:
            self.skipTest("Set upstream path for optional preprocessing parity")
        import numpy as np
        module_path = Path(root)/"ST-GCN/asl_citizen_dataset_pose.py"
        spec = importlib.util.spec_from_file_location("citizen_reference_pose", module_path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        rng = np.random.default_rng(91)
        with tempfile.TemporaryDirectory() as directory:
            for length in (1, 20, 127, 128, 129, 251):
                data = rng.random((length, 75, 2))
                path = Path(directory)/"pose.npy"
                np.save(path, data)
                dataset = module.ASLCitizen.__new__(module.ASLCitizen)
                dataset.pose_paths = [str(path)]
                dataset.labels = [0]
                dataset.gloss_dict = {"HELLO": 0}
                dataset.max_frames = 128
                dataset.transforms = None
                dataset.video_info = [["synthetic", "synthetic", "HELLO"]]
                expected = dataset[0][0].numpy()
                np.testing.assert_allclose(citizen.pose_tensor(data), expected, atol=1e-12)

    def test_i3d_adapter_matches_original_dataset(self):
        root = os.environ.get("SIGNLOOP_CITIZEN_UPSTREAM")
        if not root:
            self.skipTest("Set upstream path for optional preprocessing parity")
        import cv2
        import numpy as np
        modules = {}
        for name in ("aslcitizen_dataset", "videotransforms"):
            spec = importlib.util.spec_from_file_location(name, Path(root)/"I3D"/(name+".py"))
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            modules[name] = module
        with tempfile.TemporaryDirectory() as directory:
            for length in (12, 64, 100, 170):
                video = str(Path(directory)/"synthetic.avi")
                writer = cv2.VideoWriter(video, cv2.VideoWriter_fourcc(*"MJPG"), 30, (320, 240))
                self.assertTrue(writer.isOpened())
                for i in range(length):
                    image = np.zeros((240, 320, 3), dtype=np.uint8)
                    image[:, :, 0] = i % 255
                    image[:, :, 1] = 60
                    image[:, :, 2] = 200
                    writer.write(image)
                writer.release()
                dataset = modules["aslcitizen_dataset"].ASLCitizen.__new__(
                    modules["aslcitizen_dataset"].ASLCitizen)
                dataset.video_paths = [video]
                dataset.video_info = [["synthetic", "synthetic", "HELLO"]]
                dataset.labels = [0]
                dataset.gloss_dict = {"HELLO": 0}
                dataset.transforms = modules["videotransforms"].CenterCrop(224)
                np.random.seed(7)
                expected = dataset[0][0].numpy()
                np.random.seed(7)
                np.testing.assert_array_equal(citizen.rgb_tensor(video), expected)


if __name__ == "__main__":
    unittest.main()
