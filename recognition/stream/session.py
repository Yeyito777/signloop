"""Concurrent streaming session: capture, windowing, provider inference, fusion, temporal resolution,
contextual reranking and caption building all run at the same time.

  push_frame()  (camera thread, never blocks)  -> rolling buffer -> emits a Window every `stride` seconds
  window worker (1 thread, ordered)            -> all providers in parallel (thread pool) -> fuse -> resolver
  context pool  (async)                        -> Jev only when the state is ambiguous; result lands later
  snapshot()    (UI/X-Ray thread)              -> the live state, including tentative/stable/committed words

Window N+1 can be captured and inferred while window N's context call is still in flight.
"""
from __future__ import annotations

from collections import deque
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
import queue
import threading
import time

import numpy as np

from . import fusion, temporal
from .context import Candidate, ContextResolver, NoContext, UNKNOWN
from .provider import ProviderResult, RecognitionProvider, Window


@dataclass
class SessionConfig:
    width: float = 1.0
    stride: float = 0.25
    k: int = 5
    resolver: temporal.ResolverConfig = field(default_factory=temporal.ResolverConfig)
    ambiguity_conf: float = 0.6        # ask the context resolver only if fused top prob is below this
    ambiguity_margin: float = 0.2      # ... or top1-top2 is below this
    cooldown_windows: int | None = None   # after a commit, ignore evidence this many windows; default = one window width
                                          # (a 2 s window still contains the sign for 2 s: shorter re-commits the same sign)


class StreamingSession:
    def __init__(self, providers: dict[str, RecognitionProvider], vocab: np.ndarray, glosses: list[str],
                 cfg: SessionConfig = SessionConfig(), context: ContextResolver | None = None):
        self.providers, self.vocab, self.glosses, self.cfg = providers, np.asarray(vocab), glosses, cfg
        self.context = context or NoContext()
        self.resolver = temporal.TemporalResolver(cfg.resolver)
        self._buf: deque = deque()                 # (t, keypoints, conf)
        self._last_emit = None
        self._q: queue.Queue = queue.Queue(maxsize=8)
        self._pool = ThreadPoolExecutor(max(len(providers), 1), thread_name_prefix="provider")
        self._ctx_pool = ThreadPoolExecutor(2, thread_name_prefix="context")
        self._lock = threading.Lock()
        self._alive = True
        self._last_results: dict[str, ProviderResult] = {}
        self._recent_top: deque = deque(maxlen=6)
        self._recent_fused: deque = deque(maxlen=6)
        self.committed: list[str] = []
        self._cool = 0
        self._cool_n = cfg.cooldown_windows if cfg.cooldown_windows is not None else int(np.ceil(cfg.width / cfg.stride))
        self._step = 0
        self._ctx = {"resolved": None, "confidence": None, "stable": False, "commit": False, "latency_ms": None, "pending": False, "ok": True}
        self._state = {"state": "unknown", "top": [], "confidence": 0.0}
        self._fps_marks: deque = deque(maxlen=60)
        self.windows_done = 0
        self.dropped_windows = 0
        self.log: list[dict] = []
        self._worker = threading.Thread(target=self._run, daemon=True, name="window-worker")
        self._worker.start()

    # ---------------- camera side
    def push_frame(self, t: float, keypoints: np.ndarray, conf: np.ndarray | None = None):
        self._buf.append((t, keypoints, conf))
        self._fps_marks.append(time.perf_counter())
        while self._buf and self._buf[0][0] < t - self.cfg.width - 1e-6:
            self._buf.popleft()
        if self._last_emit is None:
            self._last_emit = t
        if t - self._last_emit + 1e-9 >= self.cfg.stride and self._buf[-1][0] - self._buf[0][0] >= self.cfg.width * 0.6:
            self._last_emit = t
            w = Window(self._buf[0][0], t, np.stack([b[1] for b in self._buf]),
                       None if self._buf[0][2] is None else np.stack([b[2] for b in self._buf]))
            try:
                self._q.put_nowait(w)                       # never block the camera; count drops
            except queue.Full:
                self.dropped_windows += 1

    # ---------------- inference side
    def _run(self):
        while self._alive:
            try:
                w = self._q.get(timeout=0.1)
            except queue.Empty:
                continue
            futs = {n: self._pool.submit(p.infer, w, self.vocab, 10) for n, p in self.providers.items()}
            results = {n: f.result() for n, f in futs.items()}
            self._update(w, results)

    def _update(self, w: Window, results: dict[str, ProviderResult]):
        pos = {g: i for i, g in enumerate(self.glosses[int(v)] for v in self.vocab)}
        V = len(self.vocab)
        per = {}
        for n, r in results.items():
            arr = np.full(V, 1e-9)
            for lab, p in r.predictions:
                arr[pos[lab]] = p
            per[n] = arr / arr.sum()
        fused = fusion.geo_mean(list(per.values()))
        if self._cool > 0:
            self._cool -= 1
            self.resolver.reset()
            state = {"state": "unknown", "top": [], "confidence": 0.0}
        else:
            state = self.resolver.step(fused)
        self._recent_fused.append(fused)
        names = [self.glosses[int(self.vocab[i])] for i in state["top"] and [t[0] for t in state["top"]]]
        ctx_needed = state["state"] in ("tentative", "stable", "committed") and (
            state["confidence"] < self.cfg.ambiguity_conf or state["margin"] < self.cfg.ambiguity_margin)
        if state["state"] in ("stable", "committed") and ctx_needed and not self._ctx["pending"]:
            self._launch_context(fused, per, state)
        with self._lock:
            self.windows_done += 1
            self._step += 1
            self._last_results = results
            self._state = {**state, "labels": names, "window": (w.t0, w.t1)}
            if state["state"] == "committed":
                c = self._ctx
                # A context answer is only usable if it was requested recently AND names one of the current candidates;
                # otherwise it is stale (earlier sign) and the visual top-1 stands.
                fresh = (c["resolved"] not in (None, UNKNOWN) and c["ok"] and c.get("step") is not None
                         and self._step - c["step"] <= 6 and c["resolved"] in names[: self.cfg.k])
                label = c["resolved"] if fresh else names[0]
                self.committed.append(label)
                self._cool = self._cool_n
                self._ctx.update(resolved=label if fresh else None, commit=True, pending=False, stable=fresh, step=None)
                self.resolver.reset()
            self.log.append({"t": w.t1, "state": state["state"], "top": names[:3], "conf": round(state["confidence"], 3),
                             "latency_ms": {n: round(r.latency_ms, 1) for n, r in results.items()}})

    def _launch_context(self, fused, per, state):
        cands = []
        top_idx = [t[0] for t in state["top"]][: self.cfg.k]
        for i in top_idx:
            cands.append(Candidate(self.glosses[int(self.vocab[i])], float(state["top"][top_idx.index(i)][1]),
                                   {n.replace("openhands-wlasl2000-", ""): float(per[n][i]) for n in per},
                                   sum(int(f.argmax() == i) for f in self._recent_fused)))
        recent = [[(self.glosses[int(self.vocab[j])], float(f[j])) for j in np.argsort(-f)[:3]] for f in self._recent_fused]
        prev = list(self.committed)
        with self._lock:
            self._ctx["pending"] = True
            step = self._step

        def job():
            d = self.context.resolve(prev, cands, recent)
            with self._lock:
                self._ctx.update(resolved=d.resolved, confidence=round(d.confidence, 3), stable=True, latency_ms=round(d.latency_ms),
                                 pending=False, ok=d.ok, commit=False, step=step)
        self._ctx_pool.submit(job)

    # ---------------- observation
    def snapshot(self) -> dict:
        with self._lock:
            marks = list(self._fps_marks)
            fps = (len(marks) - 1) / (marks[-1] - marks[0]) if len(marks) > 2 and marks[-1] > marks[0] else 0.0
            st = self._state
            tentative = st.get("labels", [None])[0] if st.get("state") in ("tentative", "stable") else None
            return {"camera_fps": fps, "windows_queued": self._q.qsize(), "windows_done": self.windows_done, "dropped": self.dropped_windows,
                    "providers": {n: [(l, p) for l, p in r.predictions[:3]] for n, r in self._last_results.items()},
                    "provider_latency_ms": {n: r.latency_ms for n, r in self._last_results.items()},
                    "temporal": {"state": st.get("state"), "top": st.get("labels", [])[:3], "confidence": st.get("confidence")},
                    "context": dict(self._ctx), "committed": list(self.committed), "tentative": tentative}

    def close(self):
        self._alive = False
        self._worker.join(timeout=2)
        self._pool.shutdown(wait=False)
        self._ctx_pool.shutdown(wait=False)
