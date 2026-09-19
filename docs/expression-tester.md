# Expression lab

Open the standalone native app and tap the smiling-face button beside the
skeleton inspector. This is an on-device experiment mapping visible movements
to five named presets. It does not estimate a person's internal emotional state,
interpret ASL grammar, change captions, or drive the goose/voice adapter.
The Expo consumer camera remains unchanged.

## Try it

1. Keep one face in view, facing the camera. The preview and five raw score
   readouts show whether the detector responds to each movement.
2. Tap **Capture relaxed face · 2 s** and keep your face relaxed.
3. On each cue card, follow the instruction and tap **Calibrate … · 2 s**.
   Hold a comfortable expression until capture finishes, then relax.
4. Repeat the movement. **Level** is the smoothed score within the measured
   range; the white mark and slider set its activation threshold. Move the
   slider left for more sensitivity, or right to reduce unwanted activations.
5. A single cue must remain above threshold for 300 ms to select its preset.
   Multiple qualifying cues show **Ambiguous**. No qualifying cue shows
   **No clear cue**, and missing tracking shows **No face** or **Signal unavailable**.
6. Test normal signing, questions, talking, blinking, occlusion, and head turns.
   Count missed cues and unwanted preset activations, not just successful poses.

Calibration and sliders stay in RAM for this app session, including across
closing and reopening the lab. Pause, face loss, switching cameras, or stale
frames clear the active/pending result. They interrupt in-progress calibration
without discarding previous completed ranges. Recalibrate for another person,
camera angle, or lighting setup. **Reset calibration & thresholds** clears the
whole profile. No images or measurements are saved or uploaded.

## One movement per preset

| Preset | Movement | MediaPipe coefficients |
| --- | --- | --- |
| Joy | Smile | mean of mouthSmileLeft, mouthSmileRight |
| Anger | Lowered brows | mean of browDownLeft, browDownRight |
| Fear | Wide eyes | mean of eyeWideLeft, eyeWideRight |
| Sadness | Raised inner brows | browInnerUp |
| Disgust | Raised upper lip | mean of mouthUpperUpLeft, mouthUpperUpRight |

These are experimental associations, not validated emotion labels. Furrowed
brows can mark ASL wh-questions; wide eyes can accompany surprise. The preset
must not be treated as the meaning or tone of a signed phrase.

## Rules and calibration

ExpressionCues.swift contains a pure Swift state machine independent of
camera hardware. The view feeds it the existing, freshness-checked
SkeletonFrame.expressions and capture timestamp. The default raw range is
0–1. Default activation thresholds are tuned separately after initial phone
feedback: joy/sadness already responded well; anger/fear/disgust needed more
sensitivity. These are starting values for further testing, not validated cutoffs.

| Preset | Default activation | Minimum calibration range |
| --- | --- | --- |
| Joy | 0.50 | 0.10 |
| Anger | 0.30 | 0.04 |
| Fear | 0.25 | 0.04 |
| Sadness | 0.50 | 0.10 |
| Disgust | 0.30 | 0.04 |

All five previously used 0.55 activation and a 0.10 minimum range. Existing
slider overrides still take precedence. Reset calibration/thresholds to return
to these defaults. The same activation values can be tried immediately with
the sliders in the previous build; the updated calibration needs a new build.

- Baseline: median of two seconds of relaxed-face observations, plus the
  90th–10th percentile spread to measure variation at rest.
- Cue endpoint: 90th percentile of two seconds of that cue. It must exceed the
  baseline by the larger of the cue's minimum range above or five times its
  relaxed-face spread. This accepts smaller, stable brow/eye/upper-lip movements
  while rejecting flat or noisy signals. A rejected capture preserves the
  previous range and explains that the signal barely changed.
- Normalization: clamp (raw − baseline) / (endpoint − baseline) to 0–1.
  Uncalibrated endpoints are 1; the denominator uses the same minimum-range bound.
- Smoothing: time-based exponential smoothing with a 120 ms time constant.
- Activation: one qualifying cue held across fresh observations for 300 ms.
- Release: threshold minus the smaller of 0.12 or 25% of that threshold.
  This reduces flicker while letting weaker cues clear when the face relaxes.
- Conflict: any second qualifying cue clears the selected preset.
- Missing/non-finite/out-of-range coefficients invalidate the decision.
  Missing bilateral channels are never substituted with zeros.
- Duplicate timestamps do not advance timers. Backward timestamps invalidate
  the reading; gaps over 400 ms restart holds and abort calibration.
- Calibration requires at least eight observations, stores at most 120 samples
  per cue, and never emits a preset while capturing.

All levels describe movement, not calibrated probabilities. A flat channel
cannot be repaired by reducing its threshold until noise activates it.
Inspect the raw values before relying on a mapping. In particular, eyeWide
and several nose/mouth channels have reported limitations.

## Checks

Run bash ios/scripts/test-core.sh for deterministic coverage of every cue,
calibration, ambiguous inputs, missing signals, hysteresis, timestamp behavior,
and lifecycle resets. Native UI tests cover the no-face state, disabled
calibration, and threshold editing/persistence. Simulator tests do not establish
live facial-cue accuracy.

For a small pilot, use several participants, repeat each deliberate cue, and
include ordinary signing and ASL questions as negative/control trials. Tune on
one session and assess on a later session or held-out participant. Record counts
manually; this prototype has no recording/export feature.

## Research basis

- [MediaPipe Face Landmarker](https://ai.google.dev/edge/mediapipe/solutions/vision/face_landmarker)
  supplies facial landmarks and blendshape coefficients.
- [Facial action patterns](https://pmc.ncbi.nlm.nih.gov/articles/PMC3992629/)
  motivate candidate movements, not a one-to-one mapping to felt emotion.
- [ASL facial grammar](https://pmc.ncbi.nlm.nih.gov/articles/PMC2632943/)
  explains why lowered brows can be grammatical rather than anger.
- [Reported blendshape limitations](https://github.com/google-ai-edge/mediapipe/issues/5329)
  motivate measuring signal response on the target device.
