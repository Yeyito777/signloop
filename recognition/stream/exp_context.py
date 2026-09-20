"""Experiment C: does contextual reranking (Jev) recover signs that the visual models leave ambiguous?

SIMULATED SENTENCES. WLASL only has isolated clips, so each sentence position is a real, randomly chosen
val-split clip of that gloss, judged with real inference; the sentence order is hand-authored. That
tests the reranking mechanism, not continuous ASL (no co-articulation, no real discourse). Controls:
  own       previous words = the system's own earlier outputs (realistic, errors propagate)
  oracle    previous words = ground truth (upper bound on what context can add)
  shuffled  previous words come from a DIFFERENT random sentence (nonsense context; should not help)
Reported: truth-in-candidates ceiling, visual top-1, Jev top-1 (always / gated on ambiguity), rescued,
harmed, UNKNOWN rate, latency, calls.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path

import numpy as np

from . import fusion, temporal
from .cache import get_logits
from .context import Candidate, JevResolver, UNKNOWN
from .metrics import softmax
from .openhands_provider import ARCHS, OpenHandsProvider, ROOT
from .poseio import WLASLPoses, nested_random_vocab

SENTENCES = """i want water|i need help|where bathroom|doctor help sick|i go home tomorrow|you want eat food|mother love father
i work school today|friend come home|what name|i drink water|hungry eat food|i tired sleep|book computer school|you like play
doctor hospital pain|i understand know|please help again|sorry i wait|morning work happy|night sleep good|hot water drink
cold sick doctor|i buy food money|you know name|phone call mother|car drive home|i learn book|friend meet school|father work computer
i think good|slow again please|sad family|deaf friend understand|who help you|where you go|when come home|why sad|how phone work
i want money|tell friend yesterday|ask doctor help|answer phone|i stop work|today good happy|money buy car|more water please
finish eat|bad pain hospital|see doctor tomorrow|think computer bad|hearing deaf|play again|need water hot|love family|like school""".replace("\n", "|").split("|")


def build(P, vocab_size, seed=0, width=2.0, stride=0.25):
    rng = np.random.default_rng(seed)
    sents = [s.split() for s in SENTENCES]
    vals_by_class = {}
    for v, c, _ in P.split("val"):
        vals_by_class.setdefault(c, []).append(v)
    sents = [s for s in sents if all(w in P.gloss_id and P.gloss_id[w] in vals_by_class for w in s)]
    needed = sorted({P.gloss_id[w] for s in sents for w in s})
    base = list(nested_random_vocab(len(P.glosses), [vocab_size], seed)[vocab_size]) if vocab_size < len(P.glosses) else list(range(len(P.glosses)))
    vocab = np.array(sorted(set(base) | set(needed)))
    words = []                                    # (sentence index, position, gloss, video_id)
    for si, s in enumerate(sents):
        for pi, w in enumerate(s):
            words.append((si, pi, w, str(rng.choice(vals_by_class[P.gloss_id[w]]))))
    return sents, vocab, words


def word_evidence(P, providers, words, vocab, width=2.0, stride=0.25):
    """Per word: per-window probs of each provider over vocab (real inference, cached)."""
    key = "ctx_" + hashlib.md5(json.dumps([w[3] for w in words]).encode()).hexdigest()[:10]
    plan = []
    for wi, (_, _, _, vid) in enumerate(words):
        kp, _ = P.clip(vid)
        for t0, t1 in temporal.make_windows(len(kp) / 25.0, width, stride):
            plan.append((wi, t0, t1))
    ev = {}
    for a, prov in providers.items():
        z, _ = get_logits(prov, f"{key}_{width}_{stride}", lambda: [P.window(words[wi][3], t0, t1) for wi, t0, t1 in plan])
        ev[a] = softmax(z[:, vocab])
    wi_idx = np.array([p[0] for p in plan])
    return ev, wi_idx


def candidates_for(P, vocab, ev, wi_idx, wi, K):
    rows = np.flatnonzero(wi_idx == wi)
    per = {a: ev[a][rows] for a in ev}
    fused = np.stack([fusion.mean_prob([per[a][r:r + 1] for a in per])[0] for r in range(len(rows))])   # (n_w, V) fused per window
    S = temporal.agg_mean(fused)
    top = np.argsort(-S)[:K]
    win_top1 = fused.argmax(1)
    cands = [Candidate(P.glosses[int(vocab[i])], float(S[i]), {a.replace("openhands-wlasl2000-", ""): float(per[a][:, i].mean()) for a in per},
                       int((win_top1 == i).sum())) for i in top]
    recent = [[(P.glosses[int(vocab[j])], float(f[j])) for j in np.argsort(-f)[:3]] for f in fused]
    return cands, recent


def run(vocab_size, K, out, seed=0, workers=8, conditions=("own", "oracle", "shuffled"), style="conservative"):
    P = WLASLPoses(ROOT / "WLASL_pose.zip", ROOT / "wlasl_metadata/splits/asl2000.json")
    providers = {k: OpenHandsProvider(k, P.glosses) for k in ARCHS}
    sents, vocab, words = build(P, vocab_size, seed)
    ev, wi_idx = word_evidence(P, providers, words, vocab)
    cand = {wi: candidates_for(P, vocab, ev, wi_idx, wi, K) for wi in range(len(words))}
    jev = JevResolver(style=style)
    rng = np.random.default_rng(seed + 1)
    by_sent = {}
    for wi, (si, pi, g, vid) in enumerate(words):
        by_sent.setdefault(si, []).append(wi)
    other = {si: [w[2] for w in words if w[0] == int(rng.choice([x for x in by_sent if x != si]))][:3] for si in by_sent}

    def run_sentence(item):
        cond, si = item
        outs, prev_own = [], []
        for wi in by_sent[si]:
            g = words[wi][2]
            cands, recent = cand[wi]
            if cond == "own":
                prev = list(prev_own)
            elif cond == "oracle":
                prev = [words[x][2] for x in by_sent[si][:by_sent[si].index(wi)]]
            else:
                prev = list(other[si])
            d = jev.resolve(prev, cands, recent)
            vis = cands[0]
            outs.append({"word": g, "cond": cond, "ambiguous": vis.visual < 0.6 or (len(cands) > 1 and vis.visual - cands[1].visual < 0.2),
                         "in_cands": g in [c.label for c in cands], "visual_top1": vis.label, "visual_p": vis.visual,
                         "jev": d.resolved, "jev_conf": d.confidence, "jev_scores": d.scores, "visual_scores": {c.label: c.visual for c in cands}, "ok": d.ok, "err": d.error, "latency_ms": d.latency_ms,
                         "prev": prev})
            prev_own.append(d.resolved if (d.ok and d.resolved != UNKNOWN) else vis.label)
        return outs

    jobs = [(c, si) for c in conditions for si in by_sent]
    with ThreadPoolExecutor(workers) as pool:
        rows = [r for res in pool.map(run_sentence, jobs) for r in res]
    Path(out).write_text(json.dumps({"style": style, "vocab_size": int(len(vocab)), "K": K, "sentences": len(sents), "words": len(words), "rows": rows}))
    return summarize(rows, len(words), len(vocab), K)


def summarize(rows, n_words, V, K):
    out = {"vocab": V, "K": K, "words": n_words}
    for cond in sorted({r["cond"] for r in rows}):
        rs = [r for r in rows if r["cond"] == cond]
        ok = [r for r in rs if r["ok"]]
        vis = np.mean([r["visual_top1"] == r["word"] for r in rs])
        ceiling = np.mean([r["in_cands"] for r in rs])
        jev_always = np.mean([(r["jev"] == r["word"]) if r["ok"] else (r["visual_top1"] == r["word"]) for r in rs])
        gated = [((r["jev"] if (r["ambiguous"] and r["ok"]) else r["visual_top1"]) == r["word"]) for r in rs]
        rescued = sum(1 for r in ok if r["visual_top1"] != r["word"] and r["jev"] == r["word"])
        harmed = sum(1 for r in ok if r["visual_top1"] == r["word"] and r["jev"] != r["word"])
        out[cond] = {"n": len(rs), "truth_in_candidates": float(ceiling), "visual_top1": float(vis), "jev_always_top1": float(jev_always),
                     "jev_gated_top1": float(np.mean(gated)), "rescued": rescued, "harmed": harmed,
                     "harmed_by_unknown": sum(1 for r in ok if r["visual_top1"] == r["word"] and r["jev"] == UNKNOWN),
                     "unknown_rate": float(np.mean([r["jev"] == UNKNOWN for r in ok])) if ok else None,
                     "failed_calls": len(rs) - len(ok), "ambiguous_frac": float(np.mean([r["ambiguous"] for r in rs])),
                     "latency_ms_p50": float(np.percentile([r["latency_ms"] for r in ok], 50)) if ok else None,
                     "latency_ms_p95": float(np.percentile([r["latency_ms"] for r in ok], 95)) if ok else None}
    return out


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--vocab", type=int, default=500)
    ap.add_argument("--k", type=int, default=5)
    ap.add_argument("--style", default="conservative", choices=["conservative", "balanced"])
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    print(json.dumps(run(a.vocab, a.k, a.out, style=a.style), indent=1))
