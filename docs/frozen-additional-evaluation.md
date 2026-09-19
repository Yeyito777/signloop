# Frozen additional-recording evaluation

## Selection frozen before downloading frames

This experiment starts from app policy commit `94de100` (installed runtime source
`d3d8ef8`, build 7). No confidence, motion, ILY, window or display thresholds are
changed for the evaluation. The private local manifest hashes the native
recognition policies, cadence implementation, metadata and Google gesture model.
The pretrained model still verifies its own exact model/vocabulary hashes.

The previous local clip cache contained 147 downloaded recordings involving
40 of the dataset's 52 participants. Selection uses metadata/filename hashes
only, not predictions:

- All previously undownloaded HELLO / YES / NO / PLEASE / THANKYOU / ILOVEYOU
  recordings: **82 supported clips**.
- At most three globally distinct unsupported glosses per previously unused
  participant: **35 clips from 12 participants**.
- Total **117 clips**, with no overlap with the previous clip-cache snapshot.
- There is one previously unused positive signer, **for ILY only**. The five
  temporal words have **no new positive signers** in this cohort.

These are fresh recordings relative to this project's earlier evaluations,
**not proof of independence from pretrained-model training**. Unsupported ASL
signs are not natural nonsigning/fidgeting examples. Once results are inspected,
this cohort cannot be advertised as untouched in later tuning.

## Input and actual app policies

Use the fixed center <=3 seconds of every video, without removing no-hand
prefixes/suffixes or excluding poor tracking. Mirror the video before tracking.
Pinned MediaPipe Gesture Recognizer 0.10.21 returns both real landmarks and
canned handshape estimates. The 24Hz deadline sampler matches the current
camera pacing; low-source-FPS videos are not artificially upsampled.

The local iOS simulator replay uses the actual Swift:

- `LiveWindowPolicy`: bounded latest 1.2s, observed-frame sampling around 15Hz,
  >=250ms between requests, one outstanding inference, two accepted results.
- `PretrainedSignEngine`: 250-class competition, score >.4, gap >=.05, NO
  articulation >=.075 palm units.
- `LocalGestureFilter`: one-hand ILY score >=.85, lead >=.2, >=150ms hold.
- Camera UI priority: ILY overrides the temporal estimate; no hands means no
  displayed sign. Both can generate false displays and are counted together.

Actual native inference runs on the simulator with a virtual capture clock
including its measured compute duration. This is not phone FPS, wall-clock live
signing, independent human validation or end-to-end camera-to-caption latency.

## Frozen result: significant misses remain

| Label | Correct displayed clips | Any correct accepted estimate before two-result confirmation |
| --- | ---: | ---: |
| HELLO | 6/13 | 9/13 |
| YES | 8/13 | 11/13 |
| NO | 7/12 | 9/12 |
| PLEASE | 10/13 | 13/13 |
| THANK_YOU | 3/12 | 6/12 |
| ILY | 9/19 | 9/19 (already includes its own hold filter) |
| **Supported total** | **43/82** | **57/82** |

- No wrong word was displayed in the 82 supported clips; 39 stayed unknown.
- **One of 35 unsupported clips falsely displayed PLEASE**; 34 stayed unknown.
  Both clips and phases within the same person are correlated. This is not a
  general population false-positive rate or a natural nonsigning benchmark.
- Fourteen supported clips had a correct raw accepted result but no confirmed
  display. Thus both classification/context and the extra confirmation delay
  contribute to misses. This finding is not permission to drop rejection gates
  or tune on this cohort and keep calling it a fresh test.
- Across 359 learned-model calls: 216 unsupported-top-label rejections, 22
  uncertainty rejections, 5 articulation rejections and 116 accepted matches.
- First frozen run: simulator inference mean **4.50ms**, p95 **5.69ms**.
  A diagnostic-only rerun adding raw-estimate counters reproduced every displayed
  count exactly. No runtime policy changed between the runs.

This result is materially weaker than the smaller previously inspected replay.
**Good live accuracy is not established.** The phone remains on the unchanged
build-7 research policy, not a newly tuned classifier. A next policy experiment
must use the earlier calibration set, clearly label reuse of this cohort as
development diagnostics, and still obtain fresh live signer/nonsigning checks.

The extraction and selection tests passed as part of **67 Python tests** with
no skips in the research environment. Core Swift tests and the actual native
simulator replay/build passed. All 117 selected clips were retained, including
poor/missing tracking; none were silently dropped.

## Reproduce, locally only

```sh
# First command freezes the private manifest before any frame is downloaded:
python3 -m backend.research_holdout --accept-research-license \
  --metadata-dir path/to/asl-citizen --prior-clips path/to/asl-citizen/clips \
  --model ios/Signloop/Resources/gesture_recognizer.task \
  --out-dir .runtime/frozen-holdout --plan-only

# Same arguments without --plan-only, using the pinned MediaPipe/OpenCV venv,
# extract observations. Resume preserves the selection and verifies policies.
```

Copy the generated `live-replay-fixture.json` and the pinned pretrained assets
only to a disposable **local Mac simulator**, then launch
`--signloop-live-replay --benchmark-run=<unique-id>`. Check `completed` and exact
run ID in Documents/live-replay-result.json. Delete the owned simulator and its
research fixture afterward; retain only ignored local research artifacts and
aggregate results under the ASL Citizen retention restrictions.

No API key, model provider, user account or remote server is involved. Do not
commit, upload, publicly distribute or provision these research observations
to a physical phone.
