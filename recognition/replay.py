"""Offline replay: recorded landmark streams through the *same* engine code the app uses.

Used for regression tests, segmenter tuning and continuous-stream evaluation (false activations
per minute, duplicate predictions, missed signs). A stream is a list of frame dicts in the app
schema plus ground-truth intervals [(start_ms, end_ms, label)], label None = nothing signed.
"""
from __future__ import annotations

from dataclasses import replace
import itertools
import json
from pathlib import Path

import numpy as np

from .engine import Prediction, SignEngine, UNKNOWN
from .segmenter import Segmenter, SegmenterConfig


def run_stream(engine: SignEngine, frames: list[dict]):
    """-> (events, states). events: one dict per completed attempt; states: state after every frame."""
    engine.reset()
    events, states = [], []
    for f in frames:
        p = engine.update(f)
        states.append(p.state if p.label is None else "prediction")
        if p.label is not None:
            events.append({"t_ms": f["timestampMS"], "label": p.label, "confidence": p.confidence, "tier": p.tier,
                           "quality": p.tracking_quality, "segment": p.segment, "reason": p.reason})
    return events, states


def _overlap(a, b):
    return max(0, min(a[1], b[1]) - max(a[0], b[0]))


def score_stream(events, intervals, frames) -> dict:
    """Compare emitted predictions with ground truth.
      sign      interval with a supported label
      negative  interval labelled UNKNOWN (motion that is not a supported sign)
      idle      interval with label None (no hand)
    A prediction is attributed to the interval it overlaps most."""
    per = [dict(interval=iv, events=[]) for iv in intervals]
    orphan = []
    for e in events:
        seg = e["segment"] or (e["t_ms"], e["t_ms"])
        best = max(range(len(intervals)), key=lambda i: _overlap(seg, intervals[i][:2]), default=None)
        if best is None or _overlap(seg, intervals[best][:2]) == 0:
            orphan.append(e)
        else:
            per[best]["events"].append(e)
    signs = [p for p in per if p["interval"][2] not in (None, UNKNOWN)]
    negs = [p for p in per if p["interval"][2] == UNKNOWN]
    shown = lambda ev: [e for e in ev if e["tier"] == "show"]
    minutes = max((frames[-1]["timestampMS"] - frames[0]["timestampMS"]) / 60000.0, 1e-9)
    correct = sum(1 for p in signs if any(e["label"] == p["interval"][2] for e in shown(p["events"])))
    wrong = sum(1 for p in signs for e in shown(p["events"]) if e["label"] != p["interval"][2])
    idle = [p for p in per if p["interval"][2] is None]
    false_act = (sum(1 for p in negs for e in shown(p["events"])) + sum(1 for p in idle for e in shown(p["events"]))
                 + sum(1 for e in orphan if e["tier"] == "show"))
    dup = sum(max(0, len(p["events"]) - 1) for p in per)
    detected = sum(1 for p in signs if p["events"])
    return {"signs": len(signs), "sign_detected": detected, "sign_correct_shown": correct, "wrong_label_shown": wrong,
            "negatives": len(negs), "false_activations_shown": false_act,
            "false_activations_per_min": false_act / minutes, "duplicate_predictions": dup,
            "orphan_segments": len(orphan), "segments_total": len(events), "minutes": minutes}


def segmentation_only(frames, intervals, cfg: SegmenterConfig) -> dict:
    """Score the segmenter alone (no model): does each attempt yield exactly one segment, and
    does the idle time yield none?"""
    seg = Segmenter(cfg)
    segments = []
    for f in frames:
        s = seg.update(f)
        if s is not None:
            segments.append(s)
            seg.finish(f["timestampMS"])
    events = [{"t_ms": s.end_ms, "label": "?", "tier": "show", "segment": (s.start_ms, s.end_ms)} for s in segments]
    attempts = [iv for iv in intervals if iv[2] is not None]
    per = [0] * len(attempts)
    spurious = 0
    for e in events:
        ovl = [_overlap(e["segment"], iv[:2]) for iv in attempts]
        if not ovl or max(ovl) == 0:
            spurious += 1
        else:
            per[int(np.argmax(ovl))] += 1
    hit = sum(1 for n in per if n >= 1)
    return {"attempts": len(attempts), "hit": hit, "duplicates": sum(max(0, n - 1) for n in per),
            "spurious": spurious, "recall": hit / max(len(attempts), 1)}


def tune_segmenter(streams: list[tuple[list, list]], base: SegmenterConfig = SegmenterConfig(),
                   e_on=(1.0, 1.4, 1.8, 2.4, 3.2), e_off=(0.4, 0.6, 0.8, 1.1), hold=(200, 300)) -> tuple[SegmenterConfig, list]:
    """Grid search on VALIDATION streams. Objective: recall - 0.5*duplicates/attempt - spurious/attempt."""
    table, best = [], (-1e9, base)
    for on, off, h in itertools.product(e_on, e_off, hold):
        if off >= on:
            continue
        cfg = replace(base, e_on=on, e_off=off, hold_ms=h)
        tot = dict(attempts=0, hit=0, duplicates=0, spurious=0)
        for frames, intervals in streams:
            r = segmentation_only(frames, intervals, cfg)
            for k in tot:
                tot[k] += r[k]
        n = max(tot["attempts"], 1)
        score = tot["hit"] / n - 0.5 * tot["duplicates"] / n - tot["spurious"] / n
        table.append({"e_on": on, "e_off": off, "hold_ms": h, "score": score, **tot})
        if score > best[0]:
            best = (score, cfg)
    return best[1], table


def save_stream(path, frames, intervals):
    Path(path).write_text(json.dumps({"frames": frames, "intervals": intervals}))


def load_stream(path):
    d = json.loads(Path(path).read_text())
    return d["frames"], [tuple(i) for i in d["intervals"]]
