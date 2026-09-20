"""Run the full concurrent pipeline (real providers, real windows, real Jev calls) over a stream built
from real WLASL clips and print X-Ray panels as it evolves. The clips are isolated recordings joined
back to back: a stand-in for a live camera, NOT continuous signing. Pass --no-context for visual-only.

    python -m recognition.stream.xray_demo --sentence "i want water" --vocab 500 --speed 1.0 --out log.txt
"""
from __future__ import annotations

import argparse
from contextlib import ExitStack
from functools import partial
import time

import numpy as np

from .context import JevResolver, NoContext
from .openhands_provider import ARCHS, OpenHandsProvider, ROOT
from .poseio import FPS, WLASLPoses, nested_random_vocab
from .process_provider import ProcessProvider
from .session import SessionConfig, StreamingSession
from . import xray


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sentence", default="i want water")
    ap.add_argument("--vocab", type=int, default=500)
    ap.add_argument("--speed", type=float, default=1.0, help="1.0 = real time")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--no-context", action="store_true")
    ap.add_argument("--auto-confirm", action="store_true",
                    help="research playback only: confirm ready attempts without user input")
    ap.add_argument("--isolate-providers", action="store_true",
                    help="load each model in a restartable process with hard inference deadlines")
    ap.add_argument("--every", type=float, default=0.5, help="print a panel every N stream-seconds")
    ap.add_argument("--out")
    a = ap.parse_args()
    P = WLASLPoses(ROOT / "WLASL_pose.zip", ROOT / "wlasl_metadata/splits/asl2000.json")
    words = a.sentence.split()
    rng = np.random.default_rng(a.seed)
    by_class = {}
    for v, c, _ in P.split("val"):
        by_class.setdefault(c, []).append(v)
    vocab = np.array(sorted(set(nested_random_vocab(len(P.glosses), [a.vocab], a.seed)[a.vocab]) | {P.gloss_id[w] for w in words}))
    clips = [(w, str(rng.choice(by_class[P.gloss_id[w]]))) for w in words]
    providers = {k: (ProcessProvider(partial(OpenHandsProvider, k, P.glosses),
                                    f"openhands-wlasl2000-{k}", P.glosses)
                     if a.isolate_providers else OpenHandsProvider(k, P.glosses)) for k in ARCHS}
    with ExitStack() as cleanup:
        for provider in providers.values():
            if isinstance(provider, ProcessProvider):
                cleanup.callback(provider.close)
        if a.isolate_providers:
            for provider in providers.values():
                provider.warmup()
        ctx = NoContext() if a.no_context else JevResolver()
        sess = StreamingSession(providers, vocab, P.glosses, SessionConfig(), ctx)
        cleanup.callback(sess.close)
        out = []
        t_stream, next_print, wall0 = 0.0, 0.0, time.perf_counter()
        for w, vid in clips:
            kp, cf = P.clip(vid)
            out.append(f"\n>>> now signing (ground truth, hidden from the system): {w.upper()}  [{vid}, {len(kp) / FPS:.1f}s]")
            for i in range(len(kp)):
                sess.push_frame(t_stream, kp[i], cf[i])
                if a.auto_confirm:
                    attempt = sess.snapshot()["attempt"]
                    if attempt["state"] == "ready":
                        sess.confirm(attempt["attempt_id"], attempt["revision"])
                t_stream += 1 / FPS
                time.sleep(max(0.0, (t_stream / a.speed) - (time.perf_counter() - wall0)))
                if t_stream >= next_print:
                    next_print += a.every
                    out.append(f"\n--- t={t_stream:5.2f}s ---\n" + xray.render(sess.snapshot()))
        time.sleep(2.0)
        if a.auto_confirm:
            attempt = sess.snapshot()["attempt"]
            if attempt["state"] == "ready":
                sess.confirm(attempt["attempt_id"], attempt["revision"])
        out.append("\n=== FINAL ===\n" + xray.render(sess.snapshot()) + f"\n\nground truth: {a.sentence.upper()}")
    text = "\n".join(out)
    if a.out:
        open(a.out, "w").write(text)
    print(text[-3000:])


if __name__ == "__main__":
    main()
