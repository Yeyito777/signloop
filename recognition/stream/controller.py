"""Deterministic caption decisions; callers serialize access and supply monotonic time.

Temporal ``committed`` means sufficiently stable evidence, never permission to append
text. Only confirm() appends a word. Context is requested once on frozen, completed
sign evidence, so an overlapping window cannot silently change a request's meaning.
"""
from __future__ import annotations

from dataclasses import dataclass, field
import math

import numpy as np

from . import fusion, temporal
from .context import Candidate, ResolverDecision, UNKNOWN


@dataclass
class ControllerConfig:
    k: int = 5
    resolver: temporal.ResolverConfig = field(default_factory=temporal.ResolverConfig)
    ambiguity_conf: float = 0.6
    ambiguity_margin: float = 0.2
    context_timeout: float = 1.5


@dataclass(frozen=True)
class ContextRequest:
    attempt_id: int
    revision: int
    request_id: int
    deadline: float
    previous: tuple[str, ...]
    candidates: tuple[Candidate, ...]
    recent: tuple


class CaptionController:
    def __init__(self, labels: list[str], cfg: ControllerConfig, context_enabled: bool):
        self.labels, self.cfg, self.context_enabled = labels, cfg, context_enabled
        self.resolver = temporal.TemporalResolver(cfg.resolver)
        self.committed: list[str] = []
        self._next_attempt = self._next_request = 0
        self.reset()

    def reset(self, *, clear_caption=False):
        # IDs never reset: an outstanding reply cannot match a later session attempt.
        if clear_caption:
            self.committed.clear()
        self.attempt_id = None
        self.revision = 0
        self.state = "idle"
        self.reason = None
        self.ready = None
        self.request: ContextRequest | None = None
        self._clear_evidence()

    def _clear_evidence(self):
        self.resolver.reset()
        self.temporal = {"state": "unknown", "top": [], "confidence": 0.0, "margin": 0.0}
        self.candidates: list[Candidate] = []
        self.recent: list = []
        self.context = {"status": "not_requested", "pending": False, "resolved": None,
                        "confidence": None, "latency_ms": None, "ok": True}

    def start(self):
        self.reset()
        self._next_attempt += 1
        self.attempt_id = self._next_attempt
        self.state = "collecting"
        return self.attempt_id

    def discontinuity(self):
        """No smoothing or context decision may span dropped/invalid evidence."""
        if self.state != "collecting":
            return
        self.revision += 1
        self._clear_evidence()
        self.request = None
        self.reason = "evidence_gap"

    def observe(self, per: dict[str, np.ndarray], *, healthy: bool, final: bool, now: float):
        if self.state != "collecting":
            return
        self.revision += 1
        if not healthy:
            self._clear_evidence()
        if per:
            p = fusion.geo_mean(list(per.values()))
            self.temporal = self.resolver.step(p)
            self.recent.append([(self.labels[int(i)], float(p[i])) for i in np.argsort(-p)[:3]])
            self.recent = self.recent[-6:]
            self.candidates = [Candidate(self.labels[i], score, {n: float(v[i]) for n, v in per.items()},
                                         sum(bool(w) and w[0][0] == self.labels[i] for w in self.recent))
                               for i, score in self.temporal["top"][:self.cfg.k]]
        self.reason = None if healthy else "provider_unavailable"
        if not final:
            return
        self.state = "uncertain"
        if not healthy:
            return
        if self.temporal["state"] != "committed":
            self.reason = "insufficient_evidence"
            return
        ambiguous = (self.temporal["confidence"] < self.cfg.ambiguity_conf or
                     self.temporal["margin"] < self.cfg.ambiguity_margin)
        if not ambiguous:
            self.state, self.ready, self.reason = "ready", self.candidates[0].label, None
            self.context["status"] = "not_needed"
        elif not self.context_enabled:
            self.reason = "ambiguous_visual"
        else:
            self._next_request += 1
            self.request = ContextRequest(self.attempt_id, self.revision, self._next_request,
                                          now + self.cfg.context_timeout, tuple(self.committed[-6:]),
                                          tuple(self.candidates), tuple(self.recent))
            self.state, self.reason = "pending", None
            self.context.update(status="pending", pending=True)

    def tick(self, now: float):
        if self.request is not None and now >= self.request.deadline:
            self.fail_context(self.request, "timeout")

    def fail_context(self, request: ContextRequest, status: str):
        if not self._matches(request):
            return False
        self.request = None
        self.state, self.reason = "uncertain", "context_" + status
        self.context.update(status=status, pending=False, ok=False)
        return True

    def _matches(self, request):
        return (self.state == "pending" and self.request is not None and
                (request.attempt_id, request.revision, request.request_id) ==
                (self.attempt_id, self.revision, self.request.request_id))

    def resolve(self, request: ContextRequest, decision: ResolverDecision, now: float):
        self.tick(now)
        if not self._matches(request):
            return False
        if not decision.ok:
            return self.fail_context(request, decision.error_kind or "error")
        labels = {c.label for c in request.candidates} | {UNKNOWN}
        scores = decision.scores
        valid_number = lambda v: isinstance(v, (float, int)) and not isinstance(v, bool) and math.isfinite(v)
        valid = (isinstance(scores, dict) and set(scores) == labels and isinstance(decision.resolved, str) and decision.resolved in labels and
                 valid_number(decision.confidence) and 0 <= decision.confidence <= 1 and
                 valid_number(decision.latency_ms) and decision.latency_ms >= 0 and
                 all(valid_number(p) and 0 <= p <= 1 for p in scores.values()) and
                 abs(sum(scores.values()) - 1) <= .05 and
                 math.isclose(scores[decision.resolved], decision.confidence, abs_tol=1e-6) and
                 scores[decision.resolved] == max(scores.values()))
        if not valid:
            return self.fail_context(request, "malformed")
        self.request = None
        self.context.update(pending=False, resolved=decision.resolved, confidence=decision.confidence,
                            latency_ms=decision.latency_ms, ok=True)
        if decision.resolved == UNKNOWN:
            self.state, self.reason = "uncertain", "context_rejected"
            self.context["status"] = "rejected"
        else:
            self.state, self.ready, self.reason = "ready", decision.resolved, None
            self.context["status"] = "accepted"
        return True

    def confirm(self, attempt_id: int, revision: int, *, label: str | None = None):
        """Accept the exact displayed revision. An explicit label permits manual review
        of uncertain candidates, including a context rejection; it is never automatic.
        """
        if (attempt_id, revision) != (self.attempt_id, self.revision):
            return False
        if self.state not in ("ready", "uncertain"):
            return False
        chosen = label if label is not None else self.ready
        if chosen is None or chosen not in {c.label for c in self.candidates}:
            return False
        self.committed.append(chosen)
        self.state, self.ready, self.request, self.reason = "finalized", None, None, None
        return True

    def discard(self, attempt_id: int, revision: int):
        if (attempt_id, revision) != (self.attempt_id, self.revision) or self.state not in ("pending", "ready", "uncertain"):
            return False
        if self.context["pending"]:
            self.context["status"] = "cancelled"
        self.state, self.ready, self.request, self.reason = "finalized", None, None, None
        self.context["pending"] = False
        return True

    def snapshot(self):
        return {"attempt_id": self.attempt_id, "revision": self.revision, "state": self.state,
                "reason": self.reason, "ready": self.ready,
                "candidates": [(c.label, c.visual) for c in self.candidates]}
