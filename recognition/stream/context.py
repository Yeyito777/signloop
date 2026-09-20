"""Contextual reranking behind a replaceable interface.

Contract: a resolver may RERANK or REJECT the candidates the visual models proposed. It can never
return a word that is not in `candidates` (or UNKNOWN); anything else is treated as a failed call.
Jev is fed compact structured state only, never pixels or landmarks.
"""
from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
import math
from pathlib import Path
import time

UNKNOWN = "UNKNOWN"


@dataclass
class Candidate:
    label: str
    visual: float                       # temporally aggregated, fused visual probability
    per_provider: dict = field(default_factory=dict)     # provider -> probability
    windows_top1: int = 0               # how many recent windows had it as fused top-1


@dataclass
class ResolverDecision:
    resolved: str                       # a candidate label or UNKNOWN
    confidence: float
    scores: dict                        # label -> resolver probability (for fusion / analysis)
    latency_ms: float
    ok: bool = True                     # False: call failed/malformed; caller must fall back to visual order
    error: str = ""


class ContextResolver(ABC):
    name: str

    @abstractmethod
    def resolve(self, previous: list[str], candidates: list[Candidate], recent: list[list[tuple[str, float]]] | None = None) -> ResolverDecision: ...


class NoContext(ContextResolver):
    name = "visual-only"

    def resolve(self, previous, candidates, recent=None):
        top = max(candidates, key=lambda c: c.visual)
        return ResolverDecision(top.label, top.visual, {c.label: c.visual for c in candidates}, 0.0)


INSTRUCTIONS = (
    "You re-rank candidate words for a LIVE ASL-to-English caption. Visual recognizers already proposed the "
    "candidates below; you cannot add words. VISUAL EVIDENCE IS PRIMARY. Use the previous words only to break "
    "ties or promote a candidate that is already visually plausible. If no candidate has real visual support, "
    "or the evidence is inconsistent, choose UNKNOWN. Never choose a word only because it fits the sentence.")


BALANCED = (
    "You re-rank candidate words for a LIVE ASL-to-English caption. Visual recognizers already proposed the "
    "candidates below; you cannot add words. The sentence so far is a REAL signal, not just a tie-breaker: when "
    "two or more candidates have visual probabilities within a factor of about 3 of each other, prefer the one "
    "that makes the most natural sentence with the previous words. Do not pick a candidate whose visual "
    "probability is far below the leader's just because it fits. If the previous words are empty or give no "
    "information, follow the visual ranking. Choose UNKNOWN only if no candidate has meaningful visual support.")
STYLES = {"conservative": INSTRUCTIONS, "balanced": BALANCED}


class JevResolver(ContextResolver):
    """Jev via the existing Backboard gateway (backend/service.py). One structured `choice` question."""
    name = "jev"

    def __init__(self, gateway=None, env_file: str | Path = ".env", model: str = "jev-latest", provider: str = "typesafe",
                 style: str = "conservative"):
        from backend.service import Backboard, read_env
        if gateway is None:
            gateway = Backboard(read_env(Path(env_file)).get("BACKBOARD_API_KEY", ""), timeout=20)
        self.gateway, self.model, self.provider, self.style = gateway, model, provider, style

    def resolve(self, previous, candidates, recent=None):
        t = time.perf_counter()
        labels = [c.label for c in candidates]
        criteria = {}
        for c in candidates:
            prov = ", ".join(f"{p} {v:.2f}" for p, v in sorted(c.per_provider.items()))
            criteria[c.label] = (f"Visual evidence: fused probability {c.visual:.2f}; top hypothesis in "
                                 f"{c.windows_top1} of the recent windows; per-recognizer: {prov}.")
        criteria[UNKNOWN] = "No candidate has enough visual support, or the evidence is contradictory."
        state = {"previous_committed_words": previous[-6:]}
        if recent:
            state["recent_windows_top3"] = [[[l, round(p, 2)] for l, p in w[:3]] for w in recent[-4:]]
        try:
            result = self.gateway.message({
                "model_name": self.model,
                "content": "Which candidate word is being signed right now?",
                "system_one": {"state": state, "questions": {"sign": {"type": "choice", "instructions": STYLES[self.style],
                                                                       "criteria": criteria}}},
            }, self.provider)
            scores = self._parse(result, set(labels))
        except Exception as e:                      # ServiceError, malformed schema, network
            return ResolverDecision(UNKNOWN, 0.0, {}, (time.perf_counter() - t) * 1000, ok=False, error=type(e).__name__ + ": " + str(e)[:120])
        winner = max(scores, key=scores.get)
        return ResolverDecision(winner, scores[winner], scores, (time.perf_counter() - t) * 1000)

    @staticmethod
    def _parse(result: dict, labels: set[str]) -> dict:
        answer = result["system_one"]["answers"]["sign"]
        scores = answer["probabilities"]
        if answer["type"] != "choice" or set(scores) != labels | {UNKNOWN}:
            raise ValueError("resolver returned labels outside the candidate set")
        if any(type(v) not in (int, float) or not math.isfinite(v) or not 0 <= v <= 1 for v in scores.values()):
            raise ValueError("bad probability")
        if abs(sum(scores.values()) - 1) > 0.05:
            raise ValueError("probabilities do not sum to 1")
        return {k: float(v) for k, v in scores.items()}
