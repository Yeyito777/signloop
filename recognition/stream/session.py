"""Bounded streaming inference with explicit sign attempts and user confirmation.

All controller/segmenter state changes are serialized by one lock. Background
calls only complete futures; this coordinator decides whether their tagged result
still belongs to the active attempt. Capture never waits for inference.
"""
from __future__ import annotations

from collections import deque
from copy import deepcopy
from dataclasses import dataclass, field
import math
import threading
import time

import numpy as np

from recognition.segmenter import Segmenter, SegmenterConfig, State
from .context import ContextResolver, NoContext, ResolverDecision
from .controller import CaptionController, ControllerConfig
from .jobs import SingleFlight
from .provider import ProviderResult, RecognitionProvider, Window
from .process_provider import ProcessProvider
from .segmentation import holistic_frame


@dataclass
class SessionConfig(ControllerConfig):
    width: float = 1.0
    stride: float = .25
    min_window: float = .25
    provider_timeout: float = 1.0
    segmenter: SegmenterConfig = field(default_factory=SegmenterConfig)
    hand_confidence: float = .5
    log_size: int = 256


@dataclass
class _Task:
    window: Window
    attempt_id: int
    generation: int
    final: bool


class StreamingSession:
    def __init__(self, providers: dict[str, RecognitionProvider], vocab: np.ndarray, glosses: list[str],
                 cfg: SessionConfig | None = None, context: ContextResolver | None = None):
        self.cfg = cfg or SessionConfig()
        c = self.cfg
        if (any(not math.isfinite(x) or x <= 0 for x in
                (c.width, c.stride, c.min_window, c.provider_timeout, c.context_timeout)) or
                c.min_window > c.width or c.log_size < 1 or c.k < 1 or not 0 <= c.hand_confidence <= 1):
            raise ValueError("invalid session timing, size or confidence configuration")
        self.vocab = np.array(vocab, dtype=int, copy=True)
        if (self.vocab.ndim != 1 or not len(self.vocab) or len(set(self.vocab)) != len(self.vocab) or
                self.vocab.min() < 0 or self.vocab.max() >= len(glosses)):
            raise ValueError("vocab must contain distinct valid label indices")
        self.vocab.flags.writeable = False
        self.labels = [glosses[int(i)] for i in self.vocab]
        if len(set(self.labels)) != len(self.labels):
            raise ValueError("active labels must be unique")
        self.providers, self.glosses = dict(providers), list(glosses)
        self.context = context
        self.controller = CaptionController(self.labels, c, context is not None and not isinstance(context, NoContext))
        self.segmenter = Segmenter(c.segmenter)
        self._lock = threading.RLock()
        self._wake = threading.Event()
        self._slots = {n: SingleFlight("provider-" + n, self._wake) for n in self.providers}
        self._context_slot = SingleFlight("context", self._wake)
        self._context_job = None
        self._batch = None
        self._queued: _Task | None = None
        self._generation = 0
        self._alive, self._paused = True, False
        self._buf = deque()
        self._last_t = self._last_emit = None
        self._has_frames = self._rearm_on_next_frame = False
        self._fps_marks = deque(maxlen=60)
        self._last_results: dict[str, ProviderResult] = {}
        self._health = {n: {"status": "idle", "error": None} for n in self.providers}
        self.windows_done = self.dropped_windows = 0
        self.log = deque(maxlen=c.log_size)
        self._worker = threading.Thread(target=self._run, daemon=True, name="window-coordinator")
        self._worker.start()

    def push_frame(self, t: float, keypoints: np.ndarray, conf: np.ndarray | None = None,
                   *, aspect_ratio=1.0, mirrored=False):
        frame = holistic_frame(t, keypoints, conf, aspect_ratio=aspect_ratio, mirrored=mirrored,
                               min_confidence=self.cfg.hand_confidence)
        with self._lock:
            if not self._alive or self._paused:
                return
            t_ms = frame["timestampMS"]
            if self._rearm_on_next_frame:
                self.segmenter.finish(t_ms)
                self._rearm_on_next_frame = False
            if self._last_t is not None and (t_ms <= self._last_t or
                    t_ms - self._last_t > self.cfg.segmenter.max_frame_gap_ms * 4):
                self._invalidate(clear_caption=False)
                # A camera discontinuity is not evidence of releasing the sign.
                self.segmenter.finish(t_ms)
            self._last_t = t_ms
            self._has_frames = True
            self._fps_marks.append(time.monotonic())
            self._buf.append(frame)
            while self._buf and self._buf[0]["time"] < t - self.cfg.width - 1e-6:
                self._buf.popleft()
            if self._last_emit is None:
                self._last_emit = t
            segment = self.segmenter.update(frame)
            if (self.segmenter.state in (State.POSSIBLE, State.IN_PROGRESS) and
                    self.controller.state in ("idle", "finalized")):
                self.controller.start()
                self._generation += 1
                self._last_results = {}
                start = self.segmenter.possible_start - self.cfg.segmenter.preroll_ms
                while self._buf and self._buf[0]["timestampMS"] < start:
                    self._buf.popleft()
            if segment is not None:
                self._enqueue(self._window(segment.frames), final=True)
            elif self.controller.state == "collecting" and self.segmenter.state != State.PREDICTION:
                if self.segmenter.state == State.IDLE:
                    self._invalidate(clear_caption=False, reset_segmenter=False)
                elif (t - self._last_emit + 1e-9 >= self.cfg.stride and len(self._buf) >= 6 and
                      self._buf[-1]["time"] - self._buf[0]["time"] + 1e-9 >= self.cfg.min_window):
                    self._last_emit = t
                    self._enqueue(self._window(list(self._buf)), final=False)
            self._wake.set()

    def _window(self, frames):
        end = frames[-1]["time"]
        frames = [f for f in frames if f["time"] >= end - self.cfg.width - 1e-6]
        conf = (np.stack([f["confidences"] for f in frames])
                if all(f["confidences"] is not None for f in frames) else None)
        kp = np.stack([f["keypoints"] for f in frames])
        kp.flags.writeable = False
        if conf is not None:
            conf.flags.writeable = False
        return Window(frames[0]["time"], end, kp, conf)

    def _enqueue(self, w, *, final):
        if self._queued is not None:
            self.dropped_windows += 1
            self._generation += 1
            self.controller.discontinuity()
        self._queued = _Task(w, self.controller.attempt_id, self._generation, final)

    def _run(self):
        while True:
            self._wake.clear()
            with self._lock:
                if not self._alive:
                    return
                now = time.monotonic()
                self._poll_context(now)
                if self._batch is not None:
                    task, jobs, deadline = self._batch
                    if now >= deadline or all(j is None or j.future.done() for j in jobs.values()):
                        self._finish_batch(task, jobs, deadline, now)
                        self._batch = None
                if self._batch is None and self._queued is not None:
                    task, self._queued = self._queued, None
                    deadline = time.monotonic() + self.cfg.provider_timeout
                    jobs = {n: self._slots[n].submit(p.infer, task.window, self.vocab, len(self.vocab))
                            for n, p in self.providers.items()}
                    self._batch = task, jobs, deadline
                self._launch_context()
            self._wake.wait(.01)

    def _distribution(self, result, window):
        if not isinstance(result, ProviderResult) or result.vocab_size != len(self.labels):
            raise ValueError("invalid provider result")
        if (result.t0 != window.t0 or result.t1 != window.t1 or
                not math.isfinite(result.latency_ms) or result.latency_ms < 0):
            raise ValueError("invalid provider metadata")
        pairs = result.predictions
        if len(pairs) != len(self.labels) or {label for label, _ in pairs} != set(self.labels):
            raise ValueError("provider must return the full active vocabulary exactly once")
        by_label = dict(pairs)
        p = np.array([by_label[label] for label in self.labels], dtype=float)
        if not np.isfinite(p).all() or (p < 0).any() or (p > 1).any() or not np.isclose(p.sum(), 1, atol=1e-4, rtol=0):
            raise ValueError("invalid probability distribution")
        return p

    def _finish_batch(self, task, jobs, deadline, now):
        results, per = {}, {}
        for name, job in jobs.items():
            status, error = "ok", None
            if job is None:
                status = "busy"
            elif not job.future.done() or job.finished_at > deadline:
                status = "timeout"
            else:
                try:
                    result = job.future.result()
                    per[name] = self._distribution(result, task.window)
                    results[name] = result
                except BaseException as exc:
                    status, error = "error", type(exc).__name__
            self._health[name] = {"status": status, "error": error}
        self.windows_done += 1
        if (task.attempt_id != self.controller.attempt_id or task.generation != self._generation or
                self._paused or self.controller.state != "collecting"):
            return
        self._last_results = results
        self.controller.observe(per, healthy=bool(self.providers) and len(per) == len(self.providers),
                                final=task.final, now=now)
        self.log.append({"t": task.window.t1, **self.controller.snapshot(),
                         "providers": {n: h["status"] for n, h in self._health.items()}})

    def _launch_context(self):
        request = self.controller.request
        if request is None or (self._context_job is not None and self._context_job[0] == request):
            return
        job = self._context_slot.submit(self.context.resolve, list(request.previous),
                                        deepcopy(list(request.candidates)), deepcopy(list(request.recent)))
        if job is None:
            self.controller.fail_context(request, "busy")
        else:
            self._context_job = request, job

    def _poll_context(self, now):
        self.controller.tick(now)
        if self._context_job is None:
            return
        request, job = self._context_job
        if job.future.done():
            self._context_job = None
            try:
                result = job.future.result()
                if not isinstance(result, ResolverDecision):
                    self.controller.fail_context(request, "malformed")
                else:
                    self.controller.resolve(request, result, now)
            except BaseException:
                self.controller.fail_context(request, "error")

    def confirm(self, attempt_id: int, revision: int, *, label: str | None = None):
        with self._lock:
            if not self._alive or self._paused:
                return False
            accepted = self.controller.confirm(attempt_id, revision, label=label)
            if accepted:
                self.segmenter.finish(self._last_t)
            return accepted

    def discard(self, attempt_id: int, revision: int):
        with self._lock:
            discarded = self.controller.discard(attempt_id, revision)
            if discarded:
                self.segmenter.finish(self._last_t)
            return discarded

    def _invalidate(self, *, clear_caption, reset_segmenter=True):
        self._generation += 1
        self._queued = None
        self._buf.clear()
        self._last_emit = None
        self.controller.reset(clear_caption=clear_caption)
        self._last_results = {}
        if reset_segmenter:
            self.segmenter.reset()

    def reset(self, *, clear_caption=False):
        with self._lock:
            self._invalidate(clear_caption=clear_caption)
            # Apply the disarm against the next frame's clock. Repeated resets
            # and capture timestamp rebasing must not re-arm a held sign.
            self._rearm_on_next_frame = self._has_frames
            self._last_t = None
            self._fps_marks.clear()
            self._wake.set()

    def pause(self):
        with self._lock:
            self._paused = True
            self.reset()

    def resume(self):
        with self._lock:
            self._paused = False

    def snapshot(self) -> dict:
        with self._lock:
            marks = list(self._fps_marks)
            fps = (len(marks) - 1) / (marks[-1] - marks[0]) if len(marks) > 2 and marks[-1] > marks[0] else 0.0
            c = self.controller
            top = [self.labels[i] for i, _ in c.temporal["top"]]
            return {"camera_fps": fps, "windows_queued": int(self._queued is not None),
                    "windows_done": self.windows_done, "dropped": self.dropped_windows,
                    "paused": self._paused, "closed": not self._alive, "attempt": c.snapshot(),
                    "providers": {n: r.predictions[:3] for n, r in self._last_results.items()},
                    "provider_latency_ms": {n: r.latency_ms for n, r in self._last_results.items()},
                    "provider_health": {n: {**h, "running": self._slots[n].running} for n, h in self._health.items()},
                    "temporal": {"state": "stable" if c.temporal["state"] == "committed" else c.temporal["state"],
                                 "top": top, "confidence": c.temporal["confidence"]},
                    "context": {**c.context, "running": self._context_slot.running},
                    "committed": list(c.committed),
                    "tentative": top[0] if top and c.state in ("collecting", "pending", "uncertain", "ready") else None}

    def close(self):
        with self._lock:
            self._alive = False
            self._invalidate(clear_caption=False)
            self._wake.set()
        self._worker.join(timeout=1)
        for provider in self.providers.values():
            if isinstance(provider, ProcessProvider):
                provider.close()
