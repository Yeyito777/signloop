import copy
import unittest

import numpy as np
import torch

from recognition import synthetic as S
from recognition.engine import SignEngine, UNKNOWN
from recognition.features import FeatureConfig
from recognition.models import ARCHS, build_model, count_params, to_tensors
from recognition.openset import Policy
from recognition.replay import run_stream, score_stream, segmentation_only
from recognition.segmenter import Segmenter, SegmenterConfig, State

KNOWN = list(S.CLASSES)


def signer(seed=0, drop=0.0):
    rng = np.random.default_rng(seed)
    sg = S.Signer.sample(rng, seed)
    sg.drop, sg.left_handed = drop, False
    return rng, sg


def feed(seg, frames):
    out = []
    for f in frames:
        s = seg.update(f)
        if s is not None:
            out.append(s)
            seg.finish(f["timestampMS"])
    return out


class SegmenterTests(unittest.TestCase):
    def test_idle_stream_produces_nothing(self):
        rng, sg = signer()
        frames, _ = S.make_stream(sg, [("idle", "-")] * 4, rng)
        self.assertEqual(feed(Segmenter(), frames), [])

    def test_one_moving_sign_one_segment_in_order(self):
        rng, sg = signer()
        frames, iv = S.make_stream(sg, [("idle", "-"), ("sign", "S_FLAT_WAVE"), ("idle", "-")], rng)
        seg, states, out = Segmenter(), [], []
        for f in frames:
            s = seg.update(f)
            states.append(seg.state)
            if s:
                out.append(s)
                seg.finish(f["timestampMS"])
        self.assertEqual(len(out), 1)
        a, b, _ = iv[1]
        self.assertGreater(min(b, out[0].end_ms) - max(a, out[0].start_ms), 0.6 * (b - a))
        order = [s for i, s in enumerate(states) if i == 0 or s != states[i - 1]]
        self.assertLess(order.index(State.POSSIBLE), order.index(State.IN_PROGRESS))
        self.assertIn(State.PREDICTION, order)

    def test_held_pose_fires_once(self):
        rng, sg = signer()
        one, _ = S.make_sign("S_Y_STATIC", sg, rng), None
        # hold the hand still for ~6 seconds
        dt = 1000 / S.FPS
        held = []
        for i in range(int(6 * S.FPS)):
            f = copy.deepcopy(one[i % 6])
            f["timestampMS"] = int(i * dt)
            held.append(f)
        out = feed(Segmenter(), held)
        self.assertEqual(len(out), 1)                   # no repeated predictions from one sign
        self.assertEqual(out[0].reason, "static_hold")

    def test_two_signs_two_segments(self):
        rng, sg = signer(1)
        frames, _ = S.make_stream(sg, [("idle", "-"), ("sign", "S_FLAT_WAVE"), ("idle", "-"), ("sign", "S_FIST_BOB"), ("idle", "-")], rng)
        self.assertEqual(len(feed(Segmenter(), frames)), 2)

    def test_hand_entering_at_the_border_cannot_fire(self):
        rng, sg = signer(2)
        frames = S.make_negative("transition", sg, rng)
        # Force the palm core against the left edge for the whole clip.
        for f in frames:
            for h in f["hands"]:
                for j in h["joints"]:
                    j["x"] = min(j["x"], 0.01)
        self.assertEqual(feed(Segmenter(), frames), [])

    def test_out_of_order_and_stalled_frames_reset_cleanly(self):
        rng, sg = signer()
        frames, _ = S.make_stream(sg, [("idle", "-"), ("sign", "S_FLAT_WAVE"), ("idle", "-")], rng)
        seg = Segmenter()
        for f in frames[:30]:
            seg.update(f)
        seg.update(frames[10])                         # duplicate/out-of-order callback
        self.assertEqual(seg.state, State.IDLE)
        late = copy.deepcopy(frames[31])
        late["timestampMS"] += 5000                    # camera stalled
        seg.update(late)
        self.assertIn(seg.state, (State.IDLE, State.POSSIBLE))

    def test_max_duration_forces_completion(self):
        rng, sg = signer()
        cfg = SegmenterConfig(max_ms=1500)
        frames = []
        wave = S.make_sign("S_FLAT_WAVE", sg, rng, duration_s=6.0)
        out = feed(Segmenter(cfg), wave)
        self.assertGreaterEqual(len(out), 1)
        self.assertLessEqual(out[0].end_ms - out[0].start_ms, 1600)
        self.assertEqual(out[0].reason, "max_duration")

    def test_short_blips_are_discarded_and_do_not_lock_out(self):
        rng, sg = signer()
        cfg = SegmenterConfig(min_ms=900)
        frames, _ = S.make_stream(sg, [("idle", "-"), ("sign", "S_FLAT_WAVE"), ("idle", "-")], rng)
        seg = Segmenter(cfg)
        feed(seg, frames)
        self.assertTrue(seg.armed)


def stub_runner(logits):
    def run(features):
        return np.array(logits, dtype=float), np.zeros(4)
    return run


def permissive_policy(quality_min=0.0):
    return Policy("log_odds", 1.0, tau_high=0.0, tau_low=-5.0, quality_min=quality_min, known=KNOWN,
                  target_far_high=0.05, target_far_low=0.2)


class EngineTests(unittest.TestCase):
    def stream(self):
        rng, sg = signer()
        return S.make_stream(sg, [("idle", "-"), ("sign", "S_FLAT_WAVE"), ("idle", "-")], rng)

    def test_confident_prediction_is_shown_exactly_once(self):
        frames, _ = self.stream()
        logits = [0.0] * (len(KNOWN) + 1)
        logits[2] = 12.0
        events, states = run_stream(SignEngine(stub_runner(logits), permissive_policy()), frames)
        self.assertEqual([e["label"] for e in events], [KNOWN[2]])
        self.assertEqual(events[0]["tier"], "show")
        self.assertIsNotNone(events[0]["segment"])
        self.assertIn("sign_in_progress", states)

    def test_background_winner_is_unknown(self):
        frames, _ = self.stream()
        logits = [0.0] * len(KNOWN) + [9.0]
        events, _ = run_stream(SignEngine(stub_runner(logits), permissive_policy()), frames)
        self.assertEqual(events[0]["label"], UNKNOWN)

    def test_poor_tracking_is_never_shown_as_a_sign(self):
        frames, _ = self.stream()
        for i in range(0, len(frames), 4):     # lose every 4th frame: usable, but degraded
            frames[i]["hands"] = []
        logits = [0.0] * (len(KNOWN) + 1)
        logits[0] = 30.0
        events, _ = run_stream(SignEngine(stub_runner(logits), permissive_policy(quality_min=0.99)), frames)
        self.assertTrue(events)
        self.assertTrue(all(e["label"] == UNKNOWN and e["tier"] == "low_tracking" for e in events))

    def test_prediction_interface(self):
        frames, _ = self.stream()
        eng = SignEngine(stub_runner([0.0] * len(KNOWN) + [0.0]), permissive_policy())
        p = eng.update(frames[0])
        for field in ("label", "confidence", "state", "tracking_quality"):
            self.assertTrue(hasattr(p, field))
        self.assertIsNone(p.label)

    def test_replay_bookkeeping(self):
        frames, iv = self.stream()
        events = [{"t_ms": 1900, "label": "S_FLAT_WAVE", "tier": "show", "segment": (800, 1900)},
                  {"t_ms": 2000, "label": "S_FLAT_WAVE", "tier": "show", "segment": (900, 1950)},
                  {"t_ms": 100, "label": "S_Y_STATIC", "tier": "show", "segment": (0, 200)}]
        r = score_stream(events, iv, frames)
        self.assertEqual(r["sign_correct_shown"], 1)
        self.assertEqual(r["duplicate_predictions"], 1)
        self.assertEqual(r["false_activations_shown"], 1)


class ModelTests(unittest.TestCase):
    def batch(self, b=3, T=32, zeros=False):
        rng = np.random.default_rng(0)
        mk = lambda *s: np.zeros(s, np.float32) if zeros else rng.normal(0, 1, s).astype(np.float32)
        from recognition.features import GLOBAL_WIDTH, N_META, N_MOTION
        return to_tensors({"nodes": mk(b, T, 2, 21, 6), "glob": mk(b, T, 2, GLOBAL_WIDTH), "motion": mk(b, T, N_MOTION),
                           "mask": np.ones((b, T, 3), np.float32) if not zeros else np.zeros((b, T, 3), np.float32),
                           "meta": mk(b, N_META)}, "cpu")

    def test_every_architecture_maps_input_to_logits(self):
        for name in ARCHS + ["dual:gated", "dual:attention"]:
            m = build_model(name, 7).eval()
            out = m(self.batch())
            self.assertEqual(tuple(out["logits"].shape), (3, 7), name)
            self.assertTrue(torch.isfinite(out["logits"]).all(), name)
            self.assertLess(count_params(m), 500_000, name)

    def test_all_missing_input_does_not_produce_nan(self):
        for name in ("gru", "dual:concat", "stgcn", "transformer"):
            out = build_model(name, 7).eval()(self.batch(zeros=True))
            self.assertTrue(torch.isfinite(out["logits"]).all(), name)

    def test_batch_order_equivariance(self):
        m = build_model("dual:concat", 7).eval()
        b = self.batch(4)
        a = m(b)["logits"]
        perm = torch.tensor([2, 0, 3, 1])
        c = m({k: v[perm] for k, v in b.items()})["logits"]
        torch.testing.assert_close(a[perm], c, atol=1e-5, rtol=1e-4)

    def test_gradients_reach_both_streams(self):
        m = build_model("dual:gated", 7)
        m(self.batch())["logits"].sum().backward()
        self.assertGreater(m.enc.g1.lin.weight.grad.abs().sum().item(), 0)
        self.assertGreater(m.b.inp[1].weight.grad.abs().sum().item(), 0)


if __name__ == "__main__":
    unittest.main()
