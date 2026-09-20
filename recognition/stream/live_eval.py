"""Randomized evaluation mode. No cherry-picking: signs are drawn uniformly at random (seeded, logged) from the
declared vocabulary, every trial is scored, and failures stay in the log.

Sources
  wlasl      AUTOMATED regression: a random val-split clip of the drawn gloss (real inference, but NOT live people).
  poses-dir  Live trials recorded with capture_poses.py: <dir>/<gloss>__<n>.pkl. The runner prompts for each drawn
             sign, waits for you to record it, then scores it. This is the one that measures real new users.

For each trial it records the rank of the target under: each provider whole-clip, ensemble whole-clip, and
the overlapping-window temporal ensemble; top-1/3/5/10 hits, absent-from-top-10, and latency.

    python -m recognition.stream.live_eval --source wlasl --vocab 100 --trials 200 --out .runtime/stream/trials.jsonl
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import pickle
import time

import numpy as np

from . import fusion, temporal
from .metrics import softmax, wilson
from .openhands_provider import ARCHS, OpenHandsProvider, ROOT
from .poseio import FPS, WLASLPoses, nested_random_vocab
from .provider import Window


def rank_of(scores: np.ndarray, target_local: int) -> int:
    return int((scores > scores[target_local]).sum()) + 1


def score_trial(providers, kp, cf, vocab, target_local, width=2.0, stride=0.25):
    dur = len(kp) / FPS
    whole = Window(0, dur, kp, cf)
    t0 = time.perf_counter()
    PC = {a: p.probs([whole], vocab)[0] for a, p in providers.items()}
    whole_ms = (time.perf_counter() - t0) * 1000
    wins = [Window(a, b, kp[int(a * FPS):max(int(b * FPS), int(a * FPS) + 1)], None) for a, b in temporal.make_windows(dur, width, stride)]
    t0 = time.perf_counter()
    PW = {a: p.probs(wins, vocab) for a, p in providers.items()}
    win_ms = (time.perf_counter() - t0) * 1000
    ens_whole = fusion.geo_mean(list(PC.values()))
    ens_temporal = temporal.agg_geo(fusion.geo_mean(list(PW.values())))
    ranks = {f"whole:{a.replace('openhands-wlasl2000-', '')}": rank_of(p, target_local) for a, p in PC.items()}
    ranks["whole:ensemble"] = rank_of(ens_whole, target_local)
    ranks["temporal:ensemble"] = rank_of(ens_temporal, target_local)
    top5 = [int(i) for i in np.argsort(-ens_temporal)[:5]]
    return ranks, top5, {"whole_ms": whole_ms, "windows_ms": win_ms, "n_windows": len(wins), "clip_s": dur}


def summarize(rows) -> dict:
    out = {"n_trials": len(rows)}
    for key in rows[0]["ranks"]:
        r = np.array([x["ranks"][key] for x in rows])
        out[key] = {f"top{k}": {"rate": float((r <= k).mean()), "wilson95": wilson(float((r <= k).mean()), len(r))} for k in (1, 3, 5, 10)}
        out[key]["absent_from_top10"] = float((r > 10).mean())
    out["latency_ms_windows_p50"] = float(np.median([x["timing"]["windows_ms"] for x in rows]))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", choices=["wlasl", "poses-dir"], default="wlasl")
    ap.add_argument("--dir", help="poses-dir source: folder of <gloss>__<n>.pkl recordings")
    ap.add_argument("--vocab", type=int, default=100, help="size of the nested random vocabulary (seeded)")
    ap.add_argument("--vocab-seed", type=int, default=0)
    ap.add_argument("--trials", type=int, default=100)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    P = WLASLPoses(ROOT / "WLASL_pose.zip", ROOT / "wlasl_metadata/splits/asl2000.json")
    providers = {k: OpenHandsProvider(k, P.glosses) for k in ARCHS}
    vocab = nested_random_vocab(len(P.glosses), [a.vocab], a.vocab_seed)[a.vocab]
    rng = np.random.default_rng(a.seed)
    by_class = {}
    for v, c, _ in P.split("val"):
        by_class.setdefault(c, []).append(v)
    eligible = [int(c) for c in vocab if c in by_class] if a.source == "wlasl" else [int(c) for c in vocab]
    header = {"source": a.source, "vocab_size": a.vocab, "vocab_seed": a.vocab_seed, "trial_seed": a.seed,
              "selection_rule": "uniform random draw of a gloss from the nested random vocabulary; no filtering by difficulty",
              "note": "wlasl source = recorded dataset clips, not live signers" if a.source == "wlasl" else "live recordings"}
    rows, pos = [], {int(c): i for i, c in enumerate(vocab)}
    with open(a.out, "w") as f:
        f.write(json.dumps({"header": header}) + "\n")
        for n in range(a.trials):
            c = int(rng.choice(eligible))
            g = P.glosses[c]
            if a.source == "wlasl":
                vid = str(rng.choice(by_class[c]))
                kp, cf = P.clip(vid)
                ref = vid
            else:
                print(f"\nTRIAL {n + 1}/{a.trials}: perform  {g.upper()}   (record with capture_poses.py to {a.dir}/{g}__{n}.pkl)")
                path = Path(a.dir) / f"{g}__{n}.pkl"
                while not path.exists():
                    time.sleep(0.5)
                d = pickle.loads(path.read_bytes())
                kp, cf, ref = np.asarray(d["keypoints"], np.float32), np.asarray(d["confidences"], np.float32), path.name
            ranks, top5, timing = score_trial(providers, kp, cf, vocab, pos[c])
            row = {"trial": n, "target": g, "ref": ref, "ranks": ranks, "temporal_top5": [P.glosses[int(vocab[i])] for i in top5], "timing": timing}
            rows.append(row)
            f.write(json.dumps(row) + "\n")
    s = summarize(rows)
    Path(a.out).with_suffix(".summary.json").write_text(json.dumps({"header": header, **s}, indent=1))
    print(json.dumps({k: (v if not isinstance(v, dict) else {kk: (vv["rate"] if isinstance(vv, dict) and "rate" in vv else vv) for kk, vv in v.items()}) for k, v in s.items()}, indent=1))


if __name__ == "__main__":
    main()
