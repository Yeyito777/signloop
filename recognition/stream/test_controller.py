"""Controller regressions use synthetic evidence, not ASL accuracy measurements."""
from dataclasses import replace
import threading
import time
import unittest

import numpy as np

from recognition.segmenter import Segmenter, State, summarize
from recognition.stream.context import ResolverDecision, UNKNOWN
from recognition.stream.controller import CaptionController, ControllerConfig
from recognition.stream.segmentation import holistic_frame
from recognition.stream.session import SessionConfig, StreamingSession
from recognition.stream.test_stream import GLOSSES, Stub


CONFIDENT = np.array([.85, .05, .05, .05])
AMBIGUOUS = np.array([.5, .3, .1, .1])


def decision(label):
    scores = {g: .1 for g in GLOSSES + [UNKNOWN]}
    scores[label] = .6
    return ResolverDecision(label, .6, scores, 700)


def hand(x=0.0):
    kp = np.zeros((75, 3), np.float32)
    for i in range(21):
        kp[33 + i] = [.4 + (i % 5) * .02 + x, .6 - (i // 5) * .035, 0]
    return kp


def wait_for(check, timeout=2):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if check():
            return
        time.sleep(.002)
    raise AssertionError("condition did not become true")


def feed(session, start=0, end=1.0, kp=None, *, drain=True):
    kp = hand() if kp is None else kp
    for i in range(round(start * 25), round(end * 25)):
        session.push_frame(i / 25, kp)
        if drain:
            # The integration tests control acquisition, so no accidental drops or
            # machine-dependent real-time sleeps can change the evidence sequence.
            def idle():
                with session._lock:
                    return session._queued is None and session._batch is None
            wait_for(idle)


class ControllerTests(unittest.TestCase):
    def setUp(self):
        self.c = CaptionController(GLOSSES, ControllerConfig(), context_enabled=True)

    def evidence(self, p=AMBIGUOUS, *, healthy=True):
        self.c.start()
        for i in range(3):
            self.c.observe({"visual": p}, healthy=healthy, final=i == 2, now=0)
        return self.c.request

    def test_700ms_context_answer_precedes_confirmation(self):
        req = self.evidence()
        self.c.tick(.508)
        self.assertEqual(self.c.state, "pending")
        self.assertEqual(self.c.committed, [])
        self.assertFalse(self.c.confirm(self.c.attempt_id, self.c.revision))
        self.assertTrue(self.c.resolve(req, decision("drink"), .7))
        self.assertEqual(self.c.ready, "drink")
        self.assertEqual(self.c.committed, [])
        self.assertTrue(self.c.confirm(self.c.attempt_id, self.c.revision))
        self.assertEqual(self.c.committed, ["drink"])

    def test_unknown_is_a_sticky_rejection_for_this_evidence(self):
        req = self.evidence()
        self.c.resolve(req, decision(UNKNOWN), .1)
        for _ in range(48):
            self.c.observe({"visual": CONFIDENT}, healthy=True, final=True, now=.5)
        self.assertEqual(self.c.state, "uncertain")
        self.assertEqual(self.c.context["status"], "rejected")
        self.assertTrue(self.c.context["ok"])
        self.assertEqual(self.c.committed, [])
        self.assertFalse(self.c.confirm(self.c.attempt_id, self.c.revision))

    def test_rejected_candidate_can_only_be_accepted_by_explicit_manual_choice(self):
        req = self.evidence()
        self.c.resolve(req, decision(UNKNOWN), .1)
        self.assertFalse(self.c.confirm(self.c.attempt_id, self.c.revision, label="invented"))
        self.assertTrue(self.c.confirm(self.c.attempt_id, self.c.revision, label="water"))
        self.assertEqual(self.c.committed, ["water"])

    def test_context_errors_are_distinct_from_rejection(self):
        for kind in ("transport", "malformed", "error", "busy"):
            req = self.evidence()
            self.c.resolve(req, ResolverDecision(UNKNOWN, 0, {}, 0, False, error_kind=kind), .1)
            self.assertEqual(self.c.context["status"], kind)
            self.assertFalse(self.c.context["ok"])
            self.assertEqual(self.c.state, "uncertain")
            self.assertEqual(self.c.committed, [])

    def test_malformed_custom_resolver_cannot_approve(self):
        for scores in ({"invented": 1}, {**decision("drink").scores, "water": float("nan")}, []):
            req = self.evidence()
            d = decision("drink")
            d.scores = scores
            self.c.resolve(req, d, .1)
            self.assertEqual(self.c.reason, "context_malformed")
        for bad in (float("nan"), -1, 2):
            req = self.evidence()
            d = decision("drink")
            d.confidence = bad
            self.c.resolve(req, d, .1)
            self.assertEqual(self.c.reason, "context_malformed")

    def test_timeout_does_not_fall_back_or_accept_late_result(self):
        req = self.evidence()
        self.c.tick(1.5)
        self.assertFalse(self.c.context["pending"])
        self.assertEqual(self.c.reason, "context_timeout")
        self.assertFalse(self.c.resolve(req, decision("drink"), 2))
        self.assertEqual(self.c.committed, [])

    def test_exact_deadline_is_expired(self):
        req = self.evidence()
        self.assertFalse(self.c.resolve(req, decision("drink"), req.deadline))
        self.assertEqual(self.c.reason, "context_timeout")

    def test_attempt_revision_and_request_must_all_match(self):
        req = self.evidence()
        for field in ("attempt_id", "revision", "request_id"):
            stale = replace(req, **{field: getattr(req, field) + 1})
            self.assertFalse(self.c.resolve(stale, decision("drink"), .1))
            self.assertEqual(self.c.state, "pending")
        self.assertTrue(self.c.resolve(req, decision("drink"), .1))

    def test_old_reply_cannot_land_in_new_attempt_with_same_candidates(self):
        old = self.evidence()
        new = self.evidence()
        self.assertNotEqual(old.attempt_id, new.attempt_id)
        self.assertFalse(self.c.resolve(old, decision("drink"), .1))
        self.assertTrue(self.c.resolve(new, decision("water"), .1))

    def test_reset_and_discard_invalidate_replies(self):
        old = self.evidence()
        self.c.reset()
        self.assertFalse(self.c.resolve(old, decision("drink"), .1))
        old = self.evidence()
        self.assertTrue(self.c.discard(self.c.attempt_id, self.c.revision))
        self.assertFalse(self.c.resolve(old, decision("drink"), .1))

    def test_ready_requires_confirmation_and_cannot_be_accepted_twice(self):
        self.evidence(CONFIDENT)
        a, r = self.c.attempt_id, self.c.revision
        self.assertEqual(self.c.state, "ready")
        self.assertEqual(self.c.committed, [])
        self.assertFalse(self.c.confirm(a, r - 1))
        self.assertTrue(self.c.confirm(a, r))
        self.assertFalse(self.c.confirm(a, r))
        for _ in range(48):
            self.c.observe({"visual": CONFIDENT}, healthy=True, final=True, now=5)
        self.assertEqual(self.c.committed, ["water"])
        self.evidence(CONFIDENT)
        self.assertTrue(self.c.confirm(self.c.attempt_id, self.c.revision))
        self.assertEqual(self.c.committed, ["water", "water"])

    def test_unvalidated_provider_subset_remains_manual(self):
        self.evidence(CONFIDENT, healthy=False)
        self.assertEqual(self.c.state, "uncertain")
        self.assertEqual(self.c.reason, "provider_unavailable")
        self.assertIsNone(self.c.request)

    def test_dropped_evidence_resets_stability(self):
        self.c.start()
        for _ in range(2):
            self.c.observe({"visual": CONFIDENT}, healthy=True, final=False, now=0)
        self.c.discontinuity()
        self.c.observe({"visual": CONFIDENT}, healthy=True, final=True, now=0)
        self.assertEqual(self.c.state, "uncertain")
        self.assertEqual(self.c.reason, "insufficient_evidence")

    def test_visual_only_ambiguity_stays_uncertain(self):
        self.c.context_enabled = False
        self.evidence()
        self.assertEqual(self.c.reason, "ambiguous_visual")
        self.assertEqual(self.c.committed, [])


class SegmentationTests(unittest.TestCase):
    def test_zero_or_low_confidence_hands_are_absent(self):
        zero = holistic_frame(0, np.zeros((75, 3)))
        self.assertFalse(summarize(zero, 0).present)
        low = holistic_frame(0, hand(), np.zeros(75))
        self.assertFalse(summarize(low, 0).present)

    def test_adapter_preserves_inputs_and_matches_mirror_aspect_conventions(self):
        kp = hand()
        frame = holistic_frame(0, kp, aspect_ratio=1.5)
        kp[:] = 0
        self.assertGreater(frame["keypoints"].sum(), 0)
        obs = summarize(frame, 0)
        self.assertIn(1, obs.slots)  # unmirrored Left follows the app's canonical Right slot
        self.assertAlmostEqual(obs.slots[1][0][0][0], (1 - .4) * 1.5, places=6)
        self.assertFalse(frame["keypoints"].flags.writeable)

    def test_held_pose_and_brief_dropout_do_not_rearm_but_release_does(self):
        s, completed = Segmenter(), []
        for i in range(300):
            kp = np.zeros((75, 3)) if 100 <= i < 103 else hand(.0002 * (i % 2))
            seg = s.update(holistic_frame(i / 25, kp))
            if seg:
                completed.append(seg)
                s.finish(i * 40)
        self.assertEqual(len(completed), 1)
        for i in range(300, 313):
            s.update(holistic_frame(i / 25, np.zeros((75, 3))))
        for i in range(313, 350):
            seg = s.update(holistic_frame(i / 25, hand()))
            if seg:
                completed.append(seg)
                s.finish(i * 40)
        self.assertEqual(len(completed), 2)

    def test_fresh_sustained_onset_rearms_without_hands_leaving(self):
        s = Segmenter()
        for i in range(50):
            seg = s.update(holistic_frame(i / 25, hand()))
            if seg:
                s.finish(i * 40)
        self.assertFalse(s.armed)
        for i in range(50, 65):
            s.update(holistic_frame(i / 25, hand((i - 50) * .008)))
        self.assertTrue(s.armed)
        self.assertEqual(s.state, State.IN_PROGRESS)

    def test_one_frame_motion_spike_does_not_rearm(self):
        s = Segmenter()
        completed = 0
        for i in range(200):
            seg = s.update(holistic_frame(i / 25, hand(.08 if i == 80 else 0)))
            if seg:
                completed += 1
                s.finish(i * 40)
        self.assertEqual(completed, 1)

    def test_invalid_frame_shapes_and_nonfinite_coordinates_are_rejected(self):
        for kp in (np.zeros((21, 3)), np.full((75, 3), np.nan)):
            with self.assertRaises(ValueError):
                holistic_frame(0, kp)


class GatedProvider(Stub):
    def __init__(self, name="gate", dist=CONFIDENT):
        super().__init__(name, dist)
        self.entered, self.release = threading.Event(), threading.Event()
        self.calls = 0

    def probs(self, windows, vocab):
        self.calls += 1
        self.entered.set()
        self.release.wait()
        return super().probs(windows, vocab)


class GatedContext:
    def __init__(self):
        self.entered, self.release = threading.Event(), threading.Event()
        self.calls = 0

    def resolve(self, *args):
        self.calls += 1
        self.entered.set()
        self.release.wait()
        return decision("drink")


class SessionRegressionTests(unittest.TestCase):
    def session(self, providers=None, **kwargs):
        s = StreamingSession(providers or {"a": Stub("a", CONFIDENT)}, np.arange(4), GLOSSES, **kwargs)
        self.addCleanup(s.close)
        return s

    def accept(self, s):
        a = s.snapshot()["attempt"]
        self.assertEqual(a["state"], "ready", s.snapshot())
        self.assertTrue(s.confirm(a["attempt_id"], a["revision"]))

    def test_hold_is_one_word_and_a_deliberate_repeat_is_two(self):
        s = self.session()
        feed(s)
        self.assertEqual(s.snapshot()["committed"], [])
        self.accept(s)
        feed(s, 1, 12)
        self.assertEqual(s.snapshot()["committed"], ["water"])
        feed(s, 12, 12.6, np.zeros((75, 3)))
        feed(s, 12.6, 14)
        self.accept(s)
        self.assertEqual(s.snapshot()["committed"], ["water", "water"])

    def test_xray_displays_actual_ready_state_and_confirmation(self):
        from recognition.stream.xray import render
        s = self.session()
        feed(s)
        panel = render(s.snapshot())
        for token in ("CAMERA", "TEMPORAL", "JEV RESOLVER", "CAPTION", "WATER", "awaiting confirmation"):
            self.assertIn(token, panel)
        self.accept(s)
        self.assertIn('"WATER"', render(s.snapshot()))

    def test_camera_gap_cannot_repeat_a_held_sign(self):
        s = self.session()
        feed(s)
        self.accept(s)
        feed(s, 5, 7)
        self.assertEqual(s.snapshot()["committed"], ["water"])
        self.assertEqual(s.snapshot()["attempt"]["state"], "idle")

    def test_repeated_pause_and_rebased_clock_require_a_new_attempt(self):
        s = self.session()
        feed(s)
        self.accept(s)
        s.pause()
        s.pause()
        s.resume()
        feed(s, 0, 2)
        self.assertEqual(s.snapshot()["attempt"]["state"], "idle")
        self.assertEqual(s.snapshot()["committed"], ["water"])
        feed(s, 2, 2.6, np.zeros((75, 3)))
        feed(s, 2.6, 4)
        self.accept(s)
        self.assertEqual(s.snapshot()["committed"], ["water", "water"])

    def test_context_waits_then_uses_reranked_word(self):
        ctx = GatedContext()
        self.addCleanup(ctx.release.set)
        s = self.session({"a": Stub("a", AMBIGUOUS)}, context=ctx)
        feed(s)
        self.assertTrue(ctx.entered.wait(1))
        self.assertEqual(s.snapshot()["attempt"]["state"], "pending")
        self.assertEqual(s.snapshot()["committed"], [])
        feed(s, 1, 3)  # more held frames cannot replace frozen evidence or spawn new calls
        self.assertEqual(ctx.calls, 1)
        ctx.release.set()
        wait_for(lambda: s.snapshot()["attempt"]["state"] == "ready")
        self.accept(s)
        self.assertEqual(s.snapshot()["committed"], ["drink"])

    def test_timed_out_context_stays_physically_running_and_is_bounded(self):
        ctx = GatedContext()
        self.addCleanup(ctx.release.set)
        s = self.session({"a": Stub("a", AMBIGUOUS)}, context=ctx, cfg=SessionConfig(context_timeout=.05))
        feed(s)
        wait_for(lambda: s.snapshot()["context"]["status"] == "timeout")
        self.assertTrue(s.snapshot()["context"]["running"])
        self.assertFalse(s.snapshot()["context"]["pending"])
        a = s.snapshot()["attempt"]
        s.discard(a["attempt_id"], a["revision"])
        feed(s, 1, 1.6, np.zeros((75, 3)))
        feed(s, 1.6, 3)
        self.assertEqual(s.snapshot()["context"]["status"], "busy")
        self.assertEqual(ctx.calls, 1)
        ctx.release.set()
        wait_for(lambda: not s.snapshot()["context"]["running"])
        self.assertEqual(s.snapshot()["attempt"]["state"], "uncertain")
        self.assertEqual(s.snapshot()["committed"], [])

    def test_pause_reset_and_close_ignore_late_context(self):
        for action in ("pause", "reset", "close"):
            with self.subTest(action=action):
                ctx = GatedContext()
                self.addCleanup(ctx.release.set)
                s = self.session({"a": Stub("a", AMBIGUOUS)}, context=ctx)
                feed(s)
                self.assertTrue(ctx.entered.wait(1))
                getattr(s, action)()
                ctx.release.set()
                wait_for(lambda: not s.snapshot()["context"]["running"])
                self.assertEqual(s.snapshot()["attempt"]["state"], "idle")
                self.assertEqual(s.snapshot()["committed"], [])

    def test_raising_and_invalid_providers_recover_without_killing_worker(self):
        class Flaky(Stub):
            mode = "raise"
            def probs(self, windows, vocab):
                if self.mode == "raise":
                    raise RuntimeError("unavailable")
                if self.mode == "nan":
                    return np.full((1, 4), np.nan)
                return super().probs(windows, vocab)
        p = Flaky("bad", CONFIDENT)
        s = self.session({"bad": p, "good": Stub("good", CONFIDENT)})
        for start, mode in ((0, "raise"), (2, "nan"), (4, "ok")):
            p.mode = mode
            if start:
                feed(s, start - 1, start, np.zeros((75, 3)))
            feed(s, start, start + 1)
            self.assertTrue(s._worker.is_alive())
            a = s.snapshot()["attempt"]
            if mode == "ok":
                self.accept(s)
            else:
                self.assertEqual(a["reason"], "provider_unavailable")
                self.assertEqual(s.snapshot()["provider_health"]["bad"]["status"], "error")
                self.assertIn("good", s.snapshot()["providers"])
                s.discard(a["attempt_id"], a["revision"])
        self.assertEqual(s.snapshot()["committed"], ["water"])

    def test_hung_provider_bounds_work_drops_old_windows_and_camera_stays_fast(self):
        p = GatedProvider()
        self.addCleanup(p.release.set)
        s = self.session({"gate": p}, cfg=SessionConfig(provider_timeout=.05))
        feed(s, 0, .4, drain=False)
        self.assertTrue(p.entered.wait(1))
        before = time.monotonic()
        feed(s, .4, 1, drain=False)
        self.assertLess(time.monotonic() - before, .1)
        wait_for(lambda: s.snapshot()["attempt"]["state"] == "uncertain")
        snap = s.snapshot()
        self.assertLessEqual(snap["windows_queued"], 1)
        self.assertGreater(snap["dropped"], 0)
        self.assertEqual(p.calls, 1)
        self.assertTrue(snap["provider_health"]["gate"]["running"])
        self.assertEqual(snap["committed"], [])
        p.release.set()
        wait_for(lambda: not s.snapshot()["provider_health"]["gate"]["running"])
        self.assertEqual(s.snapshot()["attempt"]["state"], "uncertain")
        a = snap["attempt"]
        s.discard(a["attempt_id"], a["revision"])
        feed(s, 1, 1.6, np.zeros((75, 3)))
        feed(s, 1.6, 3)
        self.accept(s)
        self.assertGreater(p.calls, 1)

    def test_provider_jobs_really_start_in_parallel(self):
        ps = {str(i): GatedProvider(str(i)) for i in range(4)}
        for p in ps.values():
            self.addCleanup(p.release.set)
        s = self.session(ps)
        feed(s, 0, .4, drain=False)
        for p in ps.values():
            self.assertTrue(p.entered.wait(1))
        self.assertEqual(s.snapshot()["windows_done"], 0)
        for p in ps.values():
            p.release.set()
        wait_for(lambda: s.snapshot()["windows_done"] > 0)

    def test_context_exception_does_not_kill_coordinator(self):
        class Broken:
            def resolve(self, *args):
                raise RuntimeError("down")
        s = self.session({"a": Stub("a", AMBIGUOUS)}, context=Broken())
        feed(s)
        wait_for(lambda: s.snapshot()["context"]["status"] == "error")
        self.assertEqual(s.snapshot()["attempt"]["state"], "uncertain")
        self.assertTrue(s._worker.is_alive())

    def test_resolver_cannot_mutate_the_controllers_evidence(self):
        class Mutating:
            def resolve(self, previous, candidates, recent):
                candidates[0].label = "invented"
                recent.clear()
                return decision("drink")
        s = self.session({"a": Stub("a", AMBIGUOUS)}, context=Mutating())
        feed(s)
        wait_for(lambda: s.snapshot()["attempt"]["state"] == "ready")
        self.assertEqual(s.snapshot()["attempt"]["candidates"][0][0], "water")
        self.accept(s)
        self.assertEqual(s.snapshot()["committed"], ["drink"])

    def test_full_distribution_is_used_instead_of_renormalized_top_ten(self):
        labels = [f"label{i}" for i in range(20)]
        p = Stub("many", [.11] + [.89 / 19] * 19)
        p.labels = labels
        s = StreamingSession({"many": p}, np.arange(20), labels)
        self.addCleanup(s.close)
        feed(s)
        self.assertAlmostEqual(s.snapshot()["temporal"]["confidence"], .11)
        self.assertEqual(s.snapshot()["attempt"]["state"], "uncertain")


if __name__ == "__main__":
    unittest.main()
