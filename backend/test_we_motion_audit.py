import copy
import unittest
from .we_motion_audit import smaller_motion, stats


class WEMotionAuditTests(unittest.TestCase):
    def test_stress_preserves_shape_depth_shoulders_and_source(self):
        clip = dict(id="synthetic", label="WE", frames=[])
        for x in (0.2, 0.6):
            clip["frames"].append(dict(hands=[dict(poseSide="Left", points=[
                dict(id=0, x=x, y=0.4, z=0.1),
                dict(id=8, x=x+0.1, y=0.3, z=0.2)])],
                pose=[dict(id=11, x=0.3, y=0.4, z=0),
                      dict(id=15, x=x, y=0.4, z=0.1)]))
        before = copy.deepcopy(clip)
        smaller = smaller_motion(clip, 0.5)
        self.assertEqual(clip, before)
        for old, new in zip(clip["frames"], smaller["frames"]):
            a, b = new["hands"][0]["points"]
            self.assertAlmostEqual(b["x"]-a["x"], 0.1)
            self.assertEqual([a["z"], b["z"]], [0.1, 0.2])
            self.assertEqual(old["pose"][0], new["pose"][0])
        x = [f["hands"][0]["points"][0]["x"] for f in smaller["frames"]]
        self.assertAlmostEqual(x[1]-x[0], 0.2)
        self.assertAlmostEqual(sum(x)/2, 0.4)

    def test_missing_evidence_is_not_fabricated(self):
        clip = dict(frames=[dict(hands=[], pose=[])])
        self.assertEqual(smaller_motion(clip), clip)

    def test_summary_counts_other_signs_and_missing_we(self):
        rows = [
            dict(id="we-missing", label="WE", events=[{}]),
            dict(id="my", label="MY", events=[dict(label="WE")]),
            dict(id="unsupported", label="OTHER", events=[dict(label="WE")]),
        ]
        r = stats(rows)
        self.assertEqual(r["supported"], 2)
        self.assertEqual(r["correct"], 0)
        self.assertEqual(r["false_we_clips"], 2)
