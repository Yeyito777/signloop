# Streaming controller fixes

Implemented on `codex/eldiiar-controller-fixes`, based on Eldiiar commit
`2285645c89b1154ab35ad3435b03dbbdc12aeb16`. This changes the research Python
controller; it does not replace the app's recognizer or connect the app to Jev.

## Behavior

| Previously observed failure | New behavior |
| --- | --- |
| Jev returned `UNKNOWN`, but the controller appended the visual winner. | A valid rejection stays uncertain for that attempt. Only an explicit manual candidate selection can accept it. Transport errors, malformed replies and rejection have different statuses. |
| Visual commitment beat a delayed context answer. | Ambiguous, completed evidence waits up to `context_timeout` (default 1.5 seconds). Timeout leaves the attempt uncertain. |
| A late context answer could overwrite shared state. | Replies must match the attempt ID, evidence revision and request ID. Reset, pause, discard, timeout and finalization invalidate them. |
| A held sign repeatedly committed after a timer expired. | The existing segmenter defines attempts. Acceptance/discard disarms it until a sustained new onset or a release. Confirmation is deduplicated by attempt, not by word. |
| An inference exception killed the window worker. | Each provider has an independent result/error status and a deadline. Healthy providers still supply tentative evidence; incomplete ensembles require manual review. |
| Slow inference accumulated old windows. | One queued window is retained, replacing the oldest. Dropping evidence resets stability and invalidates older in-flight results. |
| Truncated top-ten scores were renormalized before fusion. | Inference returns and validates the full active-vocabulary distribution. Top-k truncation is only for display/context. |

The controller progresses through `idle → collecting → pending/ready/uncertain → finalized`.
Only `confirm()` appends a word. The lower-level temporal resolver's historical
`committed` value means stable model evidence; the session exposes it as `stable`.

One sign is reviewed at a time. Completed evidence is frozen while awaiting
context or user review. Subsequent camera frames do not silently revise that
review or queue additional signs. Confirm/discard the attempt before signing the next word.

## Calling the session

```python
session.push_frame(timestamp_seconds, keypoints, confidences,
                   aspect_ratio=width / height, mirrored=False)
snapshot = session.snapshot()
attempt = snapshot["attempt"]

# On the user's confirmation action, using the revision they actually saw:
if attempt["state"] == "ready":
    accepted = session.confirm(attempt["attempt_id"], attempt["revision"])

# On an explicit manual candidate choice, including an uncertain attempt:
accepted = session.confirm(attempt["attempt_id"], attempt["revision"], label="water")

# On retry/dismiss:
discarded = session.discard(attempt["attempt_id"], attempt["revision"])
```

Inputs are image-normalized Holistic landmarks: 33 pose, 21 left hand, 21 right
hand, shape `(75, 3)`; optional confidences have shape `(75,)`. The adapter
preserves provider coordinates and converts a separate copy to the segmenter's
hand schema. Zero hand blocks mean absent when confidence is omitted. With
confidence, all palm-core landmarks must meet `hand_confidence` (default 0.5).
Pass the actual image aspect ratio and mirroring convention.

`pause()`, `reset()` and `close()` invalidate pending work. `resume()` resumes
capture. Reset preserves the caption unless `clear_caption=True`. Timestamp
discontinuities invalidate evidence and require a fresh onset/release.

The default rolling width/stride are 1 second / 250 ms. Early previews can use
250 ms and at least six frames. This warmup duration, the segmenter thresholds,
context deadline and recognition thresholds remain uncalibrated starting points.
Short signs or dropped windows can produce insufficient evidence and require
manual review rather than reducing the stability requirement.

## Failure isolation

`provider_health` exposes `idle`, `ok`, `error`, `timeout` or `busy`, plus whether
a call is physically running. Provider failures are reported by exception type;
raw service exceptions are not printed into the UI. The default inference budget
is 1 second per window, with all providers started concurrently.

In-process calls have at most one outstanding daemon thread per provider and one
for context. Logical timeout does **not** kill a Python thread. A timed-out call
retains its slot until it actually finishes; another attempt cannot spawn more
calls to that dependency. `context.pending` is logical waiting and
`context.running` is physical execution. A stuck in-process provider remains
unavailable; automatic recovery requires it to return or process isolation.

For native inference that needs hard cancellation, use `ProcessProvider` with a
picklable provider factory. It uses `spawn`, loads the model in the child, kills
the child on timeout/error and starts a fresh worker on the next call. Call
`warmup()` before capture to separate model loading from inference time. Keep its
inference timeout below the session deadline to allow shutdown overhead. Defaults
are 750 ms inference and 60 seconds startup. Session close terminates these child
processes. GPU compatibility and real model resource usage still need validation.

The X-Ray demo supports `--isolate-providers` and an explicit research-only
`--auto-confirm`. Its default shows the first reviewable attempt without accepting
it. The demo still uses concatenated isolated clips, not continuous signing.

## Validation (2026-09-20)

46 streaming tests pass: deterministic controller timing/identity checks,
event-controlled concurrent calls, frame adaptation and rearming, failures and
recovery, full-distribution fusion, plus actual spawned-process timeout, crash,
restart and shutdown tests. The nine existing non-session streaming tests remain;
the three old auto-commit/latency tests were replaced by the more complete session
regression suite. Tests use fake probabilities and synthetic hands, never live APIs.

```sh
python -m unittest discover -s recognition/stream -t . -p 'test_*.py'
python -m unittest recognition.test_features recognition.test_openset
```

The 30 existing feature/open-set tests also pass. The eight existing
`SegmenterTests` in `recognition/test_engine.py` pass when loaded separately from
that module's PyTorch-dependent engine/model tests. PyTorch and the OpenHands
checkpoints are unavailable in this environment; the full model suite was not run.

A separate controlled replay injected a real 700 ms resolver delay. At 508 ms
after request dispatch, the new controller was still pending with an empty caption.
`drink` became ready at approximately 704 ms, and entered the caption only after
explicit confirmation. Twelve seconds of simulated held-hand frames produced one
accepted `water`; a release and deliberate repeat allowed a second `water`.
The local replay record is `.runtime/controller-fixes-20260920/replay-results.json`.

These results establish controller behavior, not better ASL recognition accuracy.
A fair main-versus-Eldiiar comparison still needs the real model checkpoints and
labeled recordings, including idle motion, tracking failures, held signs,
deliberate repeats, and the app vocabulary (including `ILOVEYOU`). No DTW-to-softmax
adapter, model rollout, or live Backboard/Jev/Cerebras experiment was introduced.
