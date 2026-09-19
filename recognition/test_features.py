import copy
import math
import unittest

import numpy as np

from recognition import synthetic as S
from recognition.features import (FeatureConfig, FeatureError, featurize, featurize_frames, frames_to_raw, mirror_raw,
                                  palm_scale, N_GLOBAL, N_MOTION, N_JOINTS)


def sample(cls="S_FLAT_WAVE", seed=0, **over):
    rng = np.random.default_rng(seed)
    sg = S.Signer.sample(rng, seed)
    sg.drop, sg.left_handed = 0.0, False
    for k, v in over.items():
        setattr(sg, k, v)
    return S.make_sign(cls, sg, rng), sg


def transform(frames, scale=1.0, dx=0.0, dy=0.0):
    out = copy.deepcopy(frames)
    for f in out:
        for h in f["hands"]:
            for j in h["joints"]:
                j["x"] = j["x"] * scale + dx
                j["y"] = j["y"] * scale + dy
                j["z"] = j["z"] * scale
    return out


class NormalizationTests(unittest.TestCase):
    def test_shapes_and_finiteness(self):
        f = featurize_frames(sample()[0])
        self.assertEqual(f.nodes.shape, (32, 2, N_JOINTS, 6))
        self.assertEqual(f.glob.shape, (32, 2, 2 * N_GLOBAL))
        self.assertEqual(f.motion.shape, (32, N_MOTION))
        for a in (f.nodes, f.glob, f.motion, f.mask, f.meta):
            self.assertTrue(np.isfinite(a).all())

    def test_translation_invariance(self):
        fr, _ = sample()
        a, b = featurize_frames(fr), featurize_frames(transform(fr, dx=0.13, dy=-0.07))
        np.testing.assert_allclose(a.nodes, b.nodes, atol=1e-4)
        np.testing.assert_allclose(a.motion, b.motion, atol=1e-3)

    def test_scale_invariance_of_shape_and_trajectory(self):
        fr, _ = sample()
        a = featurize_frames(fr)
        # scaling about the image origin also scales positions; features are in palm units
        b = featurize_frames(transform(fr, scale=0.6))
        np.testing.assert_allclose(a.nodes, b.nodes, atol=1e-3)
        np.testing.assert_allclose(a.motion[:, :2], b.motion[:, :2], atol=5e-3)

    def test_wrist_is_origin_and_bone_vectors_consistent(self):
        f = featurize_frames(sample()[0])
        np.testing.assert_allclose(f.nodes[:, 1, 0, :3], 0, atol=1e-6)
        self.assertTrue(np.all(f.nodes[:, 1, 0, 3:] == 0))

    def test_palm_scale_stable_under_foreshortening(self):
        # spoke-mean scale barely changes when the hand yaws, unlike the single 2D span
        rng = np.random.default_rng(0)
        base = S.hand_pose(np.zeros(4), 0.0)
        scales = [palm_scale(S.place(base, np.zeros(2), 1.0, 0.0, yaw)) for yaw in (0.0, 0.5)]
        self.assertLess(abs(scales[0] - scales[1]) / scales[0], 0.15)

    def test_velocity_units_are_palm_lengths_per_second(self):
        rng = np.random.default_rng(0)
        sg = S.Signer.sample(rng, 0)
        sg.drop = 0.0
        sg.jitter = 0.0
        frames = []
        for i in range(25):
            j = S.place(S.hand_pose(np.zeros(4), 0.0), np.array([0.2 + 0.01 * i, 0.5]), 0.1, 0, 0)
            frames.append({"timestampMS": int(i * 1000 / 24), "imageAspectRatio": 1.0, "mirrored": True,
                           "hands": [{"handedness": "Right", "handednessScore": 1.0,
                                      "joints": [{"x": float(a), "y": float(b), "z": float(c)} for a, b, c in j]}]})
        f = featurize_frames(frames, FeatureConfig(steps=16))
        palm = palm_scale(S.place(S.hand_pose(np.zeros(4), 0.0), np.zeros(2), 0.1, 0, 0))
        expected = 0.01 * 24 / palm / 5.0   # VEL_SCALE
        vx = f.motion[3:-3, 9 + 4]
        self.assertAlmostEqual(float(np.median(vx)), expected, delta=0.03 * expected)


class MissingDataTests(unittest.TestCase):
    def test_short_gap_bridged_long_gap_masked(self):
        fr, _ = sample("S_FLAT_STATIC")
        n = len(fr)
        short, long_ = copy.deepcopy(fr), copy.deepcopy(fr)
        for i in range(n // 2, n // 2 + 2):
            short[i]["hands"] = []
        for i in range(n // 2, n // 2 + 8):
            long_[i]["hands"] = []
        ms, ml = featurize_frames(short).mask, featurize_frames(long_).mask
        self.assertTrue((ms[:, 1] == 0.5).any() and (ms[:, 1] == 0).sum() == 0)
        self.assertGreater((ml[:, 1] == 0).sum(), 0)
        # nothing is fabricated inside an unbridged gap
        f = featurize_frames(long_)
        self.assertTrue(np.all(f.nodes[f.mask[:, 1] == 0, 1] == 0))

    def test_quality_drops_with_missing_frames(self):
        fr, _ = sample("S_FLAT_STATIC")
        damaged = copy.deepcopy(fr)
        for i in range(0, len(damaged), 2):
            damaged[i]["hands"] = []
        self.assertLess(featurize_frames(damaged).tracking_quality, featurize_frames(fr).tracking_quality * 0.7)

    def test_empty_and_corrupt_inputs(self):
        with self.assertRaises(FeatureError):
            frames_to_raw([])
        fr, _ = sample()
        bad = copy.deepcopy(fr)
        bad[3]["timestampMS"] = bad[2]["timestampMS"]
        with self.assertRaises(FeatureError):
            frames_to_raw(bad)
        nan = copy.deepcopy(fr)
        nan[5]["hands"][0]["joints"][3]["x"] = float("nan")
        raw = frames_to_raw(nan)
        self.assertFalse(raw.present[5, 1])       # ignored, not propagated
        self.assertTrue(np.isfinite(featurize(raw).flat()).all())
        nohand = [{"timestampMS": i * 40, "hands": []} for i in range(10)]
        f = featurize_frames(nohand)
        self.assertEqual(f.tracking_quality, 0.0)
        with self.assertRaises(FeatureError):
            featurize_frames(fr[:1])

    def test_sequence_length_padding_and_truncation(self):
        fr, _ = sample()
        for steps in (8, 32, 64):
            self.assertEqual(featurize_frames(fr, FeatureConfig(steps=steps)).nodes.shape[0], steps)
        long_ = fr * 1
        # 300 frames still yield exactly `steps`
        rng = np.random.default_rng(1)
        sg = S.Signer.sample(rng, 1)
        big = S.make_sign("S_FLAT_WAVE", sg, rng, duration_s=12.0)
        self.assertGreater(len(big), 200)
        self.assertEqual(featurize_frames(big).nodes.shape[0], 32)


class MirrorTests(unittest.TestCase):
    def test_mirror_is_an_involution(self):
        raw = frames_to_raw(sample()[0])
        twice = mirror_raw(mirror_raw(raw))
        np.testing.assert_allclose(twice.xyz, raw.xyz)
        np.testing.assert_array_equal(twice.present, raw.present)

    def test_mirror_swaps_slots_and_flips_lateral_motion(self):
        fr, _ = sample("S_FLAT_WAVE")
        raw = frames_to_raw(fr)
        m = mirror_raw(raw)
        self.assertTrue(m.present[:, 0].all() and not m.present[:, 1].any())
        a, b = featurize(raw), featurize(m)
        np.testing.assert_allclose(a.motion[:, 0:2] * [-1, 1], b.motion[:, 9:11], atol=1e-4)

    def test_canonical_dominant_puts_moving_hand_on_the_right(self):
        fr, _ = sample("S_FLAT_WAVE")
        left = copy.deepcopy(fr)
        for f in left:
            for h in f["hands"]:
                h["handedness"] = "Left"
        f = featurize_frames(left, FeatureConfig(canonical_dominant=True))
        self.assertGreater(f.mask[:, 1].mean(), 0.9)
        self.assertLess(f.mask[:, 0].mean(), 0.1)

    def test_unmirrored_input_is_reflected(self):
        fr, _ = sample("S_FLAT_WAVE")
        un = copy.deepcopy(fr)
        for f in un:
            f["mirrored"] = False
            for h in f["hands"]:
                h["handedness"] = "Left"
                for j in h["joints"]:
                    j["x"] = 1 - j["x"]
        np.testing.assert_allclose(featurize_frames(fr).nodes, featurize_frames(un).nodes, atol=1e-4)


class AnchorTests(unittest.TestCase):
    def test_anchor_channels_only_when_present(self):
        fr, _ = sample()
        without = featurize_frames(fr)
        self.assertTrue(np.all(without.motion[:, 2:4] == 0) and without.mask[:, 2].max() == 0)
        anchored = copy.deepcopy(fr)
        for f in anchored:
            f["anchor"] = {"x": 0.5, "y": 0.3, "scale": 0.3}
        a = featurize_frames(anchored)
        self.assertGreater(np.abs(a.motion[:, 9 + 2:9 + 4]).max(), 0)
        self.assertEqual(a.mask[:, 2].min(), 1.0)
        off = featurize_frames(anchored, FeatureConfig(anchors=False))
        self.assertTrue(np.all(off.motion[:, 2:4] == 0))


if __name__ == "__main__":
    unittest.main()
