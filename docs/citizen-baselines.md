# Microsoft ASL Citizen pretrained baselines

Local research only. No app replacement, provider upload, footage export or
training from scratch. Public source does not bundle research recordings,
landmarks, checkpoint archives or model weights.

## Exact assets

Architecture repository:
<https://github.com/microsoft/ASL-citizen-code>

Pinned revision: `17f0148b00ef87a5957ec103da8d10bd8eb1fa23`.

Actual released weights:
<https://github.com/microsoft/ASL-citizen-code/releases/tag/checkpoints_v1>

| Asset | Archive SHA-256 | Extracted checkpoint SHA-256 |
| --- | --- | --- |
| ASL_citizen_stgcn_weights.zip | `4b52578ed24ed975756c6447c56ba9bb90576eb302518c9b3aef955bfb20eb01` | `b08d84afb5a0fdf4c723fd7be2db897b2490a921ccf538cff1b345f905934d68` |
| ASL_citizen_I3D_weights.zip | `42c5349f95595fac79af77a902584510da92290e802903f3c96c4689a4b19a48` | `3538319620331d5ba731e0f9ac79161deeb37a895b7680d215864fc00a14477d` |

Both checkpoints have **2731 output classes**, decoded using sorted, stripped
training-metadata glosses exactly as upstream. HELLO, MY and NAME are present.
Their presence is not evidence of sentence recognition or fingerspelling.

`torch.load(..., weights_only=True)` and strict state-dict loading are mandatory.
The adapter checks source revision, tracked modifications and checkpoint hash.
It imports reviewed architecture modules, not upstream training/test scripts
that alter devices and write files at import time.

The repository code is MIT. Do not infer that this settles all checkpoint/data
redistribution rights. ASL Citizen footage and derivatives remain subject to
the research-only dataset terms; assets stay private pending rights review.
The adapted preprocessing code retains Microsoft's MIT notice under
`backend/third_party/ASL-Citizen-LICENSE.txt`.

## Correct evaluation split matters

The existing project's V2 “test” cohort intentionally used unused **official
training participants** for its reference-matcher experiment. That is **not**
held-out data for these official pretrained models.

This new metadata-frozen manifest instead selects all locally cached recordings
in the **official validation/test splits**:

- Validation: 43 recordings / six participants.
- Test: 87 recordings / 11 participants.
- No official training recordings; all three participant sets checked disjoint.
- Six supported glosses: HELLO, YES, NO, PLEASE, THANKYOU, ILOVEYOU.
  Other glosses are unsupported-vocabulary challenges, **not natural nonsigning**.

These clips have been inspected in earlier project research. They are not
fresh live validation, nor a representative random sample of all 2731 classes.
Model checkpoints are unchanged. Rejection thresholds are selected only on
official validation, maximizing correct accepts with zero wrong accepts.
The selected policy is written **before the first test inference**.
All 2731 classes compete; there is no six-label renormalization.

## Input fidelity

**ST-GCN:** upstream MediaPipe Holistic extraction, unmirrored video, XY pose +
right hand + left hand, missing values zero. The adapter preserves upstream
128-frame downsampling/zero-padding, normalization by mean shoulder distance
(including padded frames), hand reordering and the exact 27-node graph.
Those nodes include nose/eye/body anchors and selected hand joints, **not a
full facial-expression representation**. Checkpoint and inference use float64.

**I3D:** full isolated clip, upstream centered frame skipping, 64-frame input,
resize/224 center crop, [-1,1] normalization and seeded padding. Despite being
named RGB upstream, the loader feeds **OpenCV BGR** without color conversion;
we preserve that behavior rather than silently changing the model input.
Temporal logits are linearly upsampled to 64 then max pooled, matching testing.

Synthetic parity tests compare both adapters against the original dataset
implementations across short/padded and long/downsampled sequences.
Holistic uses MediaPipe 0.10.21; the original checkpoint's exact historical
extraction runtime was not independently reproduced.

Whole-clip recognition is **not** a live-stream benchmark. The separate ST-GCN
diagnostic uses causal <=1.2-second windows, >=250ms requests, current-hand/
shoulder presence gates and two consecutive matching accepts. It separately
calibrates rejection on validation, assumes zero inference delay for scheduling,
and reports measured model compute separately. It is not the phone's UI replay.
The subsequent window comparison and hybrid run use the selected 2-second window.

## Completed baseline results — September 19, 2026

Test cohort: **72 supported recordings + 15 unsupported**, not the previous
82+35 app replay cohort. The full-clip models see complete isolated recordings;
do not compare their percentages directly with the app's rolling display metric.

| Model / protocol | Correct raw top-1 / 72 | Correct accepted / 72 | Wrong accepted | Unsupported false / 15 |
| --- | ---: | ---: | ---: | ---: |
| I3D, complete clip | 43 | 39 (54%) | 0 | 0 |
| ST-GCN, complete clip | 45 | 42 (58%) | 0 | 0 |

Validation-selected score / top-two margin thresholds:
I3D **>.30 / >=.10**, ST-GCN **>.40 / >=.20**.
These softmax scores are not calibrated probabilities.

| Label | I3D accepted | ST-GCN accepted |
| --- | ---: | ---: |
| HELLO | 5/14 | 6/14 |
| YES | 4/10 | 4/10 |
| NO | 7/11 | 6/11 |
| PLEASE | 11/13 | 10/13 |
| THANKYOU | 1/12 | 5/12 |
| ILOVEYOU | 11/12 | 11/12 |

**Streaming exposes a larger gap.** At 1.2s windows, ST-GCN correctly displayed
only **12/72** supported recordings after two matching results (25/72 had any
correct accepted raw window), with no wrong displayed words in these trials.
After this diagnostic, a validation-only fixed window grid of 1.2, 2 and 3s
selected **2s**: validation display 12/23 versus 11/23 for the other lengths.
The chosen score/margin remained >.65 / >=.30. On the now-inspected development
test cohort, 2s still displayed only **12/72** correctly (28/72 raw accepts),
with 0/15 unsupported false displays. This follow-up is not a new holdout.

Removing the score/margin gate in a post-hoc diagnostic did not fix the problem:
only 16/72 had two matching correct results, 30/72 any correct raw result.
That is not a recommendation to remove uncertainty rejection.

## Tracking and speed

Holistic produced body/shoulder coordinates in all **10,081 frames**, but hand
coordinates in only **4,239 (42%)**, including idle clip portions. Only 529 of
1,272 scheduled rolling queries passed current hand/shoulder presence checks.
This is an observation-availability statistic, **not hand-tracking accuracy**.
It motivates testing newer hand tracking rather than assuming body-aware
classification alone solves recognition.

Measured on this Mac, not on an iPhone:

| Run | Median model compute | p95 |
| --- | ---: | ---: |
| I3D, mixed Metal/CPU | 3,723ms | 4,554ms |
| ST-GCN, original float64 CPU | 415ms | 527ms |
| ST-GCN, float32 Metal, 2s rolling windows | 24.9ms | 30.5ms |

These exclude video capture and Holistic extraction. The sequential Python
Holistic extraction itself measured 139ms median / 299ms p95 per frame under
this workload; it is not an optimized native iPhone tracker.

Float32 conversion was checked against float64 on all 43 validation clips:
43/43 accept/reject decisions matched; Metal maximum absolute logit difference
was 0.0000491. The earlier CPU float32 probe also matched 43/43 decisions.
The I3D Metal/CPU run matched the CPU pilot's top-five ordering on all 18
pilot validation clips; maximum top-five score difference was 0.00000164.
Neither comparison is a phone-performance claim.

## Controlled newer-hand-tracker ablation

Keep every original body coordinate, recording, checkpoint and label unchanged.
Replace only Holistic's hand observations with MediaPipe Tasks Gesture Recognizer
0.10.21, the same model family used by the app, on the original unmirrored frames.
Use two hands and .55 detection/presence/tracking thresholds. Associate hands
geometrically to physical pose wrists, not handedness labels or array order:
unique minimum-distance assignment, maximum .25 normalized-image distance,
and at least .01 separation between assignment costs. Ambiguity becomes missing
data. Body coordinates are checked bit-exact; no frames or clips are dropped.

The separate hybrid manifest binds the original plan, task hash and association
policy before extraction. This is a development ablation after inspecting the
baseline, **not a new holdout**. Recalibrate rejection only on validation, keep
the already-selected 2-second streaming window, then evaluate all 87 test clips.

| Hybrid protocol | Validation correct / 23 | Test correct / 72 | Wrong accepted/displayed | Unsupported false / 15 |
| --- | ---: | ---: | ---: | ---: |
| Complete clip, accepted | 18 | 47 (65%) | 0 | 0 |
| Causal 2s, two-result display | 11 | 14 (19%) | 0 | 0 |

Whole-clip raw top-1 is 48/72; its rejection policy is >.25 / >=.05.
Whole-clip accepted counts: HELLO 7/14, YES 4/10, NO 8/11, PLEASE 12/13,
THANKYOU 5/12, ILOVEYOU 11/12.
The stream policy remains >.65 / >=.30; 32/72 clips have at least one correct
accepted raw window, but only 14/72 meet confirmation. Displayed counts:
HELLO 0/14, YES 1/10, NO 4/11, PLEASE 0/13, THANKYOU 2/12, ILOVEYOU 7/12.
Model-only streaming compute on this Mac is 26.3ms median / 39.9ms p95.

Newer tracking improves whole-clip acceptance from 42 to 47, but does not solve
continuous recognition. On validation, associated-hand availability is actually
1549/3784 frames versus Holistic's 1564/3784; do not attribute the gain to
recovering more hand-bearing frames or call these numbers tracker accuracy.

## Decision

**Do not replace the phone classifier with either baseline.** These are
isolated-sign models, not sentence translators. Adding body landmarks can help,
but the tested checkpoint/preprocessing/confirmation combination still performs
poorly on causal windows. Fifteen unsupported signs with no false display do not
establish reliable rejection of natural nonsigning.

The next justified direction is to adapt a pretrained temporal body/hand encoder
to the intended small vocabulary, with causal-window training, sign boundaries,
neutral movements and signer-disjoint validation—not start training from scratch
or rely on a language model to repair missing signs. This remains a proposal,
not a demonstrated improvement. MY/NAME need separate evaluation; spelling
“Aurelio” requires a fingerspelling component. The installed app is unchanged.

## Reproduce

Keep upstream, checkpoints, videos and outputs in ignored `.runtime`. Suggested
research environment: Python 3.12, torch 2.6.0, torchvision 0.21.0,
NumPy 1.26.4, MediaPipe 0.10.21, OpenCV 4.11.0.86. Pin both installed OpenCV
distributions to the same version if using MediaPipe's contrib dependency.

```sh
python -m backend.research_citizen plan --accept-research-license \
  --metadata path/to/official/csv-directory \
  --clips path/to/original/cache path/to/additional/cache \
  --out .runtime/benchmark
python -m backend.research_citizen pose --accept-research-license \
  --out .runtime/benchmark
python -m backend.research_citizen infer --accept-research-license \
  --kind stgcn --checkpoint .runtime/stgcn.pt \
  --upstream .runtime/upstream --out .runtime/benchmark
python -m backend.research_citizen infer --accept-research-license \
  --kind I3D --checkpoint .runtime/I3D.pt \
  --upstream .runtime/upstream --out .runtime/benchmark
python -m backend.research_citizen_stream --accept-research-license \
  --checkpoint .runtime/stgcn.pt --upstream .runtime/upstream \
  --out .runtime/benchmark --device mps --window-ms 2000
python -m backend.research_citizen_hybrid --accept-research-license \
  --source .runtime/benchmark --out .runtime/hybrid \
  --task ios/Signloop/Resources/gesture_recognizer.task
python -m backend.research_citizen infer --accept-research-license \
  --kind stgcn --checkpoint .runtime/stgcn.pt \
  --upstream .runtime/upstream --out .runtime/hybrid
python -m backend.research_citizen_stream --accept-research-license \
  --checkpoint .runtime/stgcn.pt --upstream .runtime/upstream \
  --out .runtime/hybrid --device mps --window-ms 2000
```

For the window experiment, first run `--validation-only` separately for
`--window-ms 1200`, `2000`, and `3000`. Select the greatest validation correct
display count with zero wrong displays, preferring the shortest window on ties.
Freeze that choice before its full diagnostic run. Keep the original baseline
report rather than relabeling a follow-up as a fresh test.

For the optional I3D Metal run, add `--device mps` and set
`PYTORCH_ENABLE_MPS_FALLBACK=1`. PyTorch 2.6 lacks MPS max-pool-3D support;
without fallback the run fails. With fallback it is **mixed GPU/CPU**, not
an all-Metal or iPhone benchmark.

`*-progress.json` files explicitly mean **incomplete**. Only complete reports
are final evaluations. Preserve the plan and caches; do not silently replace
missing/bad tracking with selectively dropped samples.

Run `SIGNLOOP_CITIZEN_UPSTREAM=.runtime/upstream python -m unittest
backend.test_citizen -v` in the research environment to include original-loader
parity tests. Without that environment, optional dependency tests may skip.

Final verification: 81 Python tests passed with the research environment and
upstream parity enabled, plus the Swift core suite. All five final whole-clip/
selected-window reports contain the same 130 unique recordings in manifest
order with matching plan hashes. No iPhone source or installed app was changed.
