# Face-context ablation — local calibration only

The pretrained model consumes selected lip/nose/eye landmarks in addition to
hands. The app currently leaves face/pose inputs as NaN. Missing facial context
could explain THANK_YOU misses, but adding another camera model has a latency
and energy cost. This experiment tests the hypothesis before changing the app.

## Fixed comparison

- Only the SHA-pinned original **32 calibration recordings / four signers**:
  17 supported, 15 unsupported. No test/additional clips were evaluated.
- Reuse the existing 24Hz, mirrored, untrimmed hand observations. Decode the
  same central <=3 seconds and verify every hand timestamp maps to a source
  frame. Hands are identical in both input variants.
- Official float16 v1 MediaPipe Face Landmarker, MediaPipe 0.10.21, two-face
  detection; accept exactly one face. Detection/presence/tracking thresholds
  are .5. Use its first 468 points, no blendshapes or identity inference.
- Compare hands-only with hands+face at **6Hz** and at every admitted hand
  frame (target **24Hz**). Hold only prior observations for <=200ms; an
  explicit missing/ambiguous face clears the hold. Never use a future face.
- Identical causal <=1.2s windows, nearest observed 15Hz samples, >=250ms
  request spacing, >=6 frames. No threshold search.
- Global 250-class competition, score >.40, top-two margin >=.05 and NO
  articulation >=.075 remain fixed. Missing pose stays NaN.

Face model:
`https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task`

SHA-256:
`64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff`

## Results

These counts mean **at least one correctly accepted raw window per recording**,
not displayed signs, end-to-end accuracy or natural nonsigning rejection.

| Input | Supported correct / 17 | Wrong supported | Unsupported false / 15 |
| --- | ---: | ---: | ---: |
| Hands only | 14 | 0 | 0 |
| Hands + 6Hz face | 15 | 0 | 0 |
| Hands + full-rate face | 14 | 0 | 0 |

The 6Hz gain was one THANK_YOU recording (1/3 -> 2/3). The full-rate
comparison did **not** reproduce a coverage gain. This small, cadence-sensitive
effect is insufficient evidence to add face tracking to the live app.

The 6Hz extraction returned one face on 475/475 requests. The full-rate
extraction returned one face on 1860/1864 requests. Missing/ambiguous outcomes
were preserved, never filled with invented coordinates.

Mac Python face inference: 6Hz median 25.8ms / p95 47.5ms; full-rate median
24.8ms / p95 49.2ms. These are **not iPhone timings**. The offline comparison
does not delay availability by face-model compute time; a real asynchronous
camera worker could perform worse. Neither camera responsiveness nor battery
cost can be inferred from this experiment.

**Decision: do not enable or bundle face tracking.** Keep build 8 unchanged.
Investigate further only with a clear benefit and phone latency validation.
No evidence here establishes good live ASL accuracy.

## Reproduction and privacy

Two environments deliberately separate MediaPipe extraction from LiteRT:

```sh
# MediaPipe 0.10.21 environment:
python -m backend.research_face extract --accept-research-license \
  --corpus path/to/corpus-v2.json \
  --hand-cache path/to/confirmation-calibration \
  --clips path/to/asl-citizen/clips \
  --face-model path/to/face_landmarker.task \
  --out-dir .runtime/face-6hz --rate 6

# ai-edge-litert 2.2.0 + NumPy environment:
python -m backend.research_face evaluate --accept-research-license \
  --corpus path/to/corpus-v2.json \
  --hand-cache path/to/confirmation-calibration \
  --model path/to/model.tflite \
  --vocabulary path/to/sign_to_prediction_index_map.json \
  --out-dir .runtime/face-6hz --rate 6
```

Repeat with `--rate 24` and a separate output directory. Full-rate extraction
uses **every already-admitted hand frame**, not a second cadence gate on
rounded timestamps. An initial doubly gated pilot was superseded and is not
reported above; incompatible cache protocols are rejected.

Cached outputs bind the corpus, hand observations, face task and rate.
Research video/face/hand coordinates stay in ignored `.runtime`, never Git,
provider requests, app resources or the physical iPhone. Follow ASL Citizen's
research license and destroy data when research ends. The pretrained weights'
distribution rights remain unresolved.

Four tests cover malformed/nonfinite face data, missing/stale/future rejection,
mirror/layout correctness without mutating hands, and bounded causal windows.
All **72 Python tests** passed with the optional research dependencies present.
