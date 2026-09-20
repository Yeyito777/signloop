# Gesture review experiments — September 20, 2026

**Revision implemented:** fresh rolling rankings now offer all three choices
immediately. Tapping a choice freezes it for separate confirmation. Gesture
completion contributes additional evidence instead of gating review. The basic
adapter uses 200 ms of elapsed-time motion history and keeps leading observations
that a late onset detector previously discarded. Trained-engine segmentation
defaults and matching/rejection thresholds are unchanged.

The same 640 generated clips were replayed three more times with alternating
policy order, without changing the generator or reference bank:

| Measurement | Original gated review | Revised live review | Contemporaneous rolling-only control |
| --- | ---: | ---: | ---: |
| Correct choice available at gesture end + 600 ms | 288/440 | **348/440** | 344/440 |
| Known clips with any review | 392/440 | **440/440** | 440/440 |
| Correct choice ever available | 376/440 | **440/440** | 440/440 |
| Median first review | 1,598 ms | **254 ms** | 254 ms |
| Top-1 correct at the fixed deadline | 268/440 | 316/440 | 320/440 |

The revised top-3 improvement over the rolling-only control is just four
synthetic cases; top-1 is four cases worse. This is not evidence of improved
real ASL classification. The important mechanical gain is removing the delay
and missing-review regressions. Unselected rankings can still change; stability
now comes from the user's explicit selection. All choices remain uncertain.

Freshness, capture generation, held-attempt suppression and the original
ten-second expiry still apply. New native contract version 4 is required.
An older segment cannot replace a newer rolling ranking within the same attempt.
Once selected, neither rolling nor completed events overwrite the choice or
renew its expiry. Confirmation and rejection suppress later results from that
attempt. Fresh movement can rearm it; **Review another sign** explicitly starts
another attempt when automatic boundaries are missed or a held pose is repeated.

The revised matcher has median/p95 service time **1.64/2.30 ms**, compared with
the contemporaneous rolling-only control's **1.64/2.31 ms**. Total matching work
is still **3.0% higher**, because final requests accompany rolling previews.
Do not compare the small raw timing difference between earlier and later Mac
runs as a speedup; the paired control is the relevant comparison.

At simulated worker service floors of 150 ms and 350 ms, revised and rolling-only
review both retain correct top-3 options on **352/440** clips at the deadline.
The original gated review had 132/440 and 104/440 respectively. At 650 ms, both
revised and rolling-only paths reject every stale result as intended. Negatives
still yield uncertain suggestions on **160/200** clips, so this revision does
not claim unknown-input rejection.

Validation: **69 mobile tests**, TypeScript, the full Swift suite (including
27 segmented-recognition checks and 161/161 existing parity checks), and direct
iPhone-SDK typechecking of the entire camera pod passed. The revised virtual
replay agrees with the actual asynchronous Swift recognizer on **all 131 usable
ranking events across eight real-time streams**, including phase, input time,
attempt identity and choices; maximum ready-time difference is below 8 ms.
Replaying all 440 known clips through the actual JS adapter and session reducer
independently reproduces **348/440**, with no automatic captions or speech.
This does not replace a full device build, visual UI verification or phone tests.

For the current revision, add `--live-review` to the main replay command below;
use a separate output such as `.runtime/gesture-experiments/revised.json`.
Run `node --experimental-strip-types scripts/replay-sign-reviews.ts
../.runtime/gesture-experiments/revised.json` from `mobile/` after generating its
summary. The following original results explain why this revision was needed.
To reproduce the original segmenter, use its source from commit `039a587`;
the current source includes the changes above. Local source hashes and outcomes
for the new run are recorded in `revision-manifest.json` and `revised*.json`.

**Original experiment, before revision**

**These are synthetic mechanism experiments, not real ASL accuracy results.**
The private reference banks and evaluation recordings mentioned in the older
research documents were unavailable in this checkout, retained worktrees and
local simulator containers. No new videos were downloaded. No camera input or
human confirmation was measured, and no production policy was tuned or changed
during the original experiment. The separately reported revision above changes
the policy using those findings; it is not a fresh blind evaluation.

The actual Swift feature extractor, DTW matcher and `BasicSignSegmentation` ran
against 56 generated references for 11 artificial classes. Classes include five
held shapes, horizontal/vertical/circular/returning motion, finger articulation
and palm rotation. None is labeled as a real ASL sign. Four generated geometry
variants per class were tested under ten fixed conditions: normal, fast, slow,
no finishing hold, 150 ms finishing hold, 10 FPS, jitter, hand dropout, body
dropout and dropped frames. Five kinds of negatives include visible unfamiliar
holds/motion and no hands. The generator is deliberately simple and related
training/test examples share its rules; these are not independent human signers.

There are **640 unique clips: 440 supported toy gestures and 200 negatives**.
All stay in the denominators. Three repetitions alternate policy order,
producing 3,840 native policy replays. Repetitions measure timing variability;
they do not triple the effective sample size. Four additional worker-delay
experiments produce another 5,120 replays. The protocol and original source
hashes were saved before inspecting results in the ignored local
`.runtime/gesture-experiments/manifest.json`.

| Measurement | Previous rolling, one choice | Rolling, three choices | Completed gesture, three choices |
| --- | ---: | ---: | ---: |
| Correct answer available 600 ms after generated gesture end | 320/440 (72.7%) | 344/440 (78.2%) | 288/440 (65.5%) |
| Correct answer ever available during the clip | 420/440 (95.5%) | 440/440 (100%) | 376/440 (85.5%) |
| Median first review availability, from clip start | 254 ms | 254 ms | 1,598 ms |
| Known clips with any review | 440/440 | 440/440 | 392/440 |
| Matcher computation, median / p95 | 1.83 / 2.91 ms | Same matcher calls | 1.84 / 2.91 ms |

“Available” means the correct label is among the currently reviewable choices,
before a user acts. Three-choice results are an **upper bound on recoverable
errors**, not the accuracy of user-confirmed captions. The fixed deadline keeps
both policies on the same clock and includes results cleared by tracking loss.
The any-time metric grants an ideal observer who notices every transient
answer; it must not be interpreted as achieved interaction accuracy.

The earlier rolling policy can produce incorrect early guesses. Its very first
choice is correct on 208/440 clips, compared with 324/440 for the first segmented
choice. Thus waiting does improve the initial snapshot in this generator.
However, by the common deadline, rolling guesses have accumulated more evidence,
while some completed-gesture choices are still missing or have discarded useful
movement. The first-choice and fixed-deadline metrics answer different questions.

Once a segmented review appears, none of these single-gesture clips produces a
second completed review. Rolling winners change 527 times across the known
clips. This is a stability benefit, but not evidence about repeated or continuous
multi-sign sentences: those require separate recordings and boundary annotations.

The fixed deadline results by condition are:

| Condition; 44 known clips each | Rolling top 1 | Rolling top 3 | Segmented top 3 |
| --- | ---: | ---: | ---: |
| Normal | 44 | 44 | 40 |
| Fast | 40 | 44 | 36 |
| Slow | 32 | 40 | 36 |
| No finishing hold | 0 | 0 | 0 |
| 150 ms finishing hold | 0 | 0 | 0 |
| 10 FPS | 44 | 44 | 24 |
| Jitter | 44 | 44 | 40 |
| Hand dropout | 36 | 42 | 36 |
| Body dropout | 36 | 42 | 36 |
| Dropped frames | 44 | 44 | 40 |

In the two short/no-hold conditions, both policies clear the review when hands
leave, before the deadline. Before that loss, rolling top 3 contains the correct
answer on all 44 clips per condition; segmented top 3 does so on only 20/44.
All 24 moving gestures in each of these conditions fail to yield a completed
review. The 20 held-shape examples finish earlier. These measurements explain
why requiring a final hold can feel unresponsive even though inference is fast.

The regression is primarily boundary selection and waiting, rather than DTW
compute. A post-result diagnostic supplied the known generated start/end to the
same whole-segment matcher: it selected the correct toy class on 440/440 clips.
That diagnostic is an **oracle, not a deployable policy or an ASL claim**. It
isolates a boundary problem on this easy artificial task:

- A normal finger-articulation gesture moves from 300–1,200 ms, but its selected
  segment starts at 966 ms and ends at 1,386 ms. The first choice becomes the
  static open-hand class. The correctly bounded sequence selects articulation.
- Slow horizontal movement ends at 2,400 ms; the chosen segment is instead the
  final still pose from 2,520–3,150 ms. The correct moving class drops out of the
  three choices. A slow vertical movement has the same failure.
- Normal palm rotation is recognized as a static hold from 1,260–1,890 ms,
  entirely after the generated movement ends at 1,200 ms. Slow rotation can
  complete prematurely instead.
- A circular gesture finishing at 1,200 ms emits its review around 1,683 ms at
  24 FPS and 2,002 ms at 10 FPS. `lagFrames = 5` corresponds to roughly 210 ms
  versus 500 ms of history, in addition to the resting hold requirement.
- `BasicSignSegmentation` immediately resets on lost hand/body tracking, so it
  cannot use the underlying segmenter's hand-left completion path. This preserves
  tracking-loss invalidation but also cancels unfinished gestures.

The negative clips receive uncertain suggestions in 160/200 rolling replays
and 116/200 segmented replays. **This is not a false-caption or false-speech
rate**: nothing is confirmed in the experiment. Fewer suggestions partly reflect
missing completions; reliable unknown-input rejection is still unestablished.

All compute measurements are optimized native Swift on an arm64 Mac, with the
same generated bank. They exclude MediaPipe, camera capture, rendering, the
Expo bridge and human reaction/selection. Measured matcher time drives the
virtual serial-worker clock. The median total matching work per 640-clip pass
is 17.086 s rolling versus 17.587 s segmented, **2.9% more**, because previews
continue alongside final requests. There are 10,560 versus 10,818 calls. The
extra work does not dominate the interaction delay.

A separate measurement gives a segmentation-update median/p95 of
0.002/0.005 ms and approximately 0.00063 ms per three-choice sort. Timing depends
on reference geometry and hardware; these figures do not establish iPhone
performance or human selection speed.

The virtual replay was cross-checked against the **actual asynchronous
`BasicLiveRecognition`** with eight streams fed in real time on the Mac:
held shape, ordinary circle, finger movement, fast/no-hold/low-FPS/slow circle,
and hand dropout. All eight agree on completed-event counts, input timestamps
and ranked choices. The largest ready-time difference is 6.6 ms. This verifies
the selected replay scenarios, not the native camera/JS/UI integration end to end.

Simulated worker service-time floors expose contention sensitivity:

| Worker service floor | Rolling top 3 at deadline | Segmented top 3 at deadline | Segmented clips with any review |
| --- | ---: | ---: | ---: |
| Measured Mac service (~2 ms) | 344/440 | 288/440 | 392/440 |
| 50 ms | 344/440 | 288/440 | 392/440 |
| 150 ms | 352/440 | 132/440 | 392/440 |
| 350 ms | 352/440 | 104/440 | 352/440 |
| 650 ms | 0/440 | 0/440 | 0/440 |

These are injected delays, not measured phone timings. The rolling ranking can
change slightly when requests are sampled less frequently. At 650 ms, the
existing 600 ms stale-result gate correctly suppresses all results. No queue
overflow occurs. Completed requests survive a busy preview worker, but queuing
adds to the segmenter's existing wait.

These findings motivated live review and improved gesture context in the
revision above. Slow and depth-dominant movement still need real-data evaluation.
Avoid simply shortening every hold or loosening freshness gates: that can create
fragmented or stale reviews. Use real
consented clips with motion-end annotations, natural nonsigning, repeated signs,
and a separate signer split before choosing thresholds. A phone test must also
measure camera-to-review latency and time for a person to choose and confirm.

Reproduce the main comparison from the repository root:

```sh
mkdir -p .runtime/gesture-experiments
swiftc -O -parse-as-library -module-cache-path .runtime/asl-module-cache \
  ios/Signloop/Recognition.swift ios/Signloop/SignSegmenter.swift \
  ios/Signloop/Skeleton.swift ios/Signloop/BasicSignMatcher.swift \
  ios/Signloop/BasicSignSegmentation.swift ios/Tools/CompareGesturePolicies.swift \
  -o .runtime/gesture-experiments/compare
.runtime/gesture-experiments/compare --repetitions 3 \
  --out .runtime/gesture-experiments/native.json
python3 -m backend.gesture_policy_report .runtime/gesture-experiments/native.json
```

Add `--service-ms 150 --repetitions 1` for a worker stress replay. Optional
`--bank /path/to/bank.json --clips /path/to/test.json` evaluates private real
inputs with the current presentation vocabulary and refuses training/evaluation
signer overlap. Real inputs without motion-end annotations do not get the
600 ms deadline metric. Preserve their source restrictions and inspected-cohort
status; keep all individual records in ignored local output.

For the live check, compile the same sources with `-D GESTURE_REPLAY_CHECK`,
adding `ios/Signloop/BasicLiveRecognition.swift` and
`ios/Tools/CheckGesturePolicyReplay.swift`; run with a local output JSON path.
For the oracle diagnostic, compile with that flag and
`ios/Tools/DiagnoseGestureBoundaries.swift` instead of the live-check source.
The source hashes for these follow-up diagnostics are recorded separately in
the local final manifest; they were added after the primary results, without
changing the production recognizer or original experiment profiles.
