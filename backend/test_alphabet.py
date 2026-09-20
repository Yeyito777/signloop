import unittest
from .alphabet_export import LETTERS, features


class AlphabetTests(unittest.TestCase):
    def test_static_vocabulary_covers_aurelio_not_motion_letters(self):
        self.assertEqual(len(LETTERS), 24)
        self.assertTrue(set("AURELIO").issubset(LETTERS))
        self.assertFalse(set("JZ") & set(LETTERS))

    def test_features_are_bounded_shape_not_labels(self):
        try:
            import numpy as np
        except ImportError:
            self.skipTest("Optional research NumPy")
        raw = np.arange(63, dtype=float)/100
        result = features(raw)
        self.assertEqual(result.shape, (86,))
        self.assertTrue(np.isfinite(result).all())
        np.testing.assert_equal(result[:63], raw)
        # Translation changes absolute XYZ but not local distance/orientation features.
        moved = features((raw.reshape(21,3)+[.1,.2,.3]).flatten())
        np.testing.assert_allclose(moved[63:], result[63:], atol=1e-7)


if __name__ == "__main__":
    unittest.main()
