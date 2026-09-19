import math
import unittest

from .research_face import face_at, inject_face, valid_face, windows


class FaceTests(unittest.TestCase):
    def setUp(self):
        self.face = [[.2, .3, -.1] for _ in range(468)]

    def test_validity(self):
        self.assertTrue(valid_face(self.face))
        for bad in (None, [], self.face[:-1], [[.2, .3]]*468,
                    [[math.nan, 0, 0]]*468, [[True, 0, 0]]*468):
            self.assertFalse(valid_face(bad))

    def test_causal_age_boundary_and_missing_reset(self):
        observations = [{"timestampMS": 100, "face": self.face},
                        {"timestampMS": 400, "face": None}]
        self.assertIsNone(face_at(observations, 99))
        self.assertEqual(face_at(observations, 300), self.face)
        self.assertIsNone(face_at(observations, 301))
        self.assertIsNone(face_at(observations, 400))
        self.assertIsNone(face_at(observations, 401))
        self.assertIsNone(face_at(list(reversed(observations)), 401))

    def test_copy_layout_and_mirroring(self):
        try:
            import numpy as np
        except ImportError:
            self.skipTest("NumPy optional research dependency")
        tensor = np.full((2, 543, 3), np.nan, dtype=np.float32)
        tensor[:, 468:489] = .7
        frames = [{"timestampMS": 100, "mirrored": False},
                  {"timestampMS": 500, "mirrored": True}]
        result = inject_face(tensor, frames, [{"timestampMS": 100, "face": self.face}])
        self.assertTrue(np.isnan(tensor[:, :468]).all())
        self.assertTrue(np.isnan(result[1, :468]).all())
        self.assertTrue(np.isnan(result[:, 489:]).all())
        np.testing.assert_allclose(result[:, 468:489], tensor[:, 468:489])
        np.testing.assert_allclose(result[0, 17], [.8, .3, -.1])

    def test_window_bounds_no_duplicates_no_future(self):
        frames = [{"timestampMS": i*40, "hands": [1]} for i in range(80)]
        result = list(windows(frames))
        self.assertTrue(result)
        last = -math.inf
        for window in result:
            stamps = [f["timestampMS"] for f in window]
            self.assertEqual(stamps, sorted(set(stamps)))
            self.assertGreaterEqual(len(stamps), 6)
            self.assertLessEqual(len(stamps), 19)
            self.assertLessEqual(stamps[-1]-stamps[0], 1200)
            self.assertGreaterEqual(stamps[-1]-last, 250)
            last = stamps[-1]
        self.assertEqual(list(windows([{"timestampMS": 0, "hands": []}])), [])


if __name__ == "__main__":
    unittest.main()
