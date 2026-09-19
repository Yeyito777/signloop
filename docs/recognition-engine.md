# Recognition engine v2: architecture, pipeline, limits

Read [the audit](recognition-audit.md) first for what this replaces. Measured numbers live in
[recognition-benchmark.md](recognition-benchmark.md).

**Scope statement.** This is a small-vocabulary, isolated-sign recognizer with explicit
rejection. It is not general ASL translation, and nothing in this repo demonstrates real-signer
accuracy yet: there is no licensed training data on the development machine, and no iPhone was
attached. Everything measured so far uses a synthetic, non-ASL generator (`S_*` classes) that
exists to prove the machinery. Read every number in the benchmark doc with that in mind.

## Pipeline

```
camera 24Hz -> MediaPipe hands (existing) -> LandmarkFrame
   -> SignSegmenter   IDLE -> POSSIBLE_SIGN -> SIGN_IN_PROGRESS -> COMPLETE -> PREDICTION
   -> (one attempted sign) SignFeatures: resample to 32 steps, two streams
   -> Core ML model (fixed shape, float16)            logits over K supported signs + UNKNOWN
   -> SignDecision: temperature + log-odds thresholds + tracking-quality gate
   -> SignPrediction {label, confidence, state, trackingQuality, tier}   -> mobile layer
```

Everything after MediaPipe is native Swift/Core ML; landmarks never cross into JS, and pixels never
leave MediaPipe. The Python reference (`recognition/`) and the Swift port
(`ios/Signloop/SignEngine*.swift`, `SignSegmenter.swift`) are held identical by golden vectors
(`ios/Tests/Fixtures/sign_engine_golden.json`, 161 checks) and, for a locally exported model, by a Core ML
logit comparison. User confirmation stays in the JS session flow: the native event is a *decision*
(`tier: show`), never a caption.

The engine is **off unless a model package is bundled**. `SignEngine.load` refuses a package whose
`manifest.json` says `shippable: false`. That flag is computed from per-sample provenance
(`recognition/data.py:assert_shippable`): any training clip not documented as redistributable makes the
model non-shippable. The existing undistributed Kaggle weights and ASL-Citizen-derived data are never used.

## Features (`recognition/features.py`)

Per attempted sign, resampled uniformly in time to T = 32 steps (speed enters only through the
duration feature and physical velocities). Missing data is explicit: mask 1 = observed, 0.5 = bridged
across a gap <= 150 ms, 0 = missing (features zero, never fabricated).

| Stream | Content | Why |
| --- | --- | --- |
| Shape (per hand, per frame) | wrist-centred, palm-scaled xyz + bone vectors; 15 joint-angle cosines, 4 abduction cosines, 10 tip-tip and 5 tip-wrist distances, palm normal, in-plane orientation; per-step deltas | hand morphology independent of distance, without discarding orientation (palm normal and roll stay) |
| Motion | wrist position relative to the sign's own start (palm units), velocity, acceleration, speed, two-hand offset; optional face/torso-relative position + anchor mask | where/how it moves, invariant to camera distance |
| Meta | log duration, tracking quality, per-hand coverage, bridged fraction, anchor coverage | speed and quality are inputs, not hidden |

Palm scale is the mean of four 3D wrist-to-knuckle spokes rather than one 2D span, so it does not
collapse when the palm foreshortens. **Body anchors are optional and currently absent on device**:
MediaPipe Gesture Recognizer returns hands only, so PLEASE/THANK_YOU-style signs (location on
face/chest) cannot be expressed relative to the signer yet. The schema, masks, dropout augmentation
and tests are ready; adding Apple Vision face/body pose (on-device) is the next step and must be
justified by an ablation on real data.

## Models and what each idea buys (`recognition/models.py`)

Seven architectures share one input/output contract so every comparison is like for like:
`single_frame`, `mlp`, `gru`, `tcn`, `transformer`, `stgcn` (graph + temporal), `dual` (graph encoder →
temporal transformer for shape, TCN for motion, fused by `concat | gated | attention`), all under 450k
parameters.

Ideas taken from the literature, and the evidence status in *this* repo:

| Idea | Failure mode addressed | Cost | Evidence here |
| --- | --- | --- | --- |
| Skeleton topology as a prior (graph conv; adjacency initialised from the hand skeleton, learnable residual). Skeleton-only recognizers are reported to be competitive with video models at a fraction of the compute ([survey](https://arxiv.org/pdf/2204.03328), [SignBART](https://arxiv.org/abs/2506.21592)) | generalising over hand shape with few parameters | small | synthetic ablation only; see benchmark |
| Separate shape and motion streams, fused late (dual-stream skeleton work, e.g. [dual-stream ST dynamic GCN](https://www.researchgate.net/publication/395401699_Skeleton-based_sign_language_recognition_using_a_dual-stream_spatio-temporal_dynamic_graph_convolutional_network)) | signs that share a handshape but differ in motion, and vice versa | ~2x a single stream | synthetic ablation only |
| Temporal (not single-frame) modelling | anything trajectory-defined | small | synthetic: single-frame fails trajectory-only pairs by construction |
| Explicit `UNKNOWN` class trained on hard negatives + calibrated thresholds | forcing an unsupported gesture into a class | training data of negatives | mechanism tested; rates unproven on real negatives |
| Temperature scaling and energy/log-odds scoring, chosen on validation ([open-set calibration caveat](https://arxiv.org/abs/2205.07160): closed-set calibration alone is not enough for rejection) | overconfident wrong signs | none at inference | measured on synthetic |
| Landmark dropout / jitter / outlier augmentation, missing-joint masks | phone tracking failures | training only | synthetic tracking-stress test |

Published isolated-sign numbers (e.g. WLASL-100 about 80% for skeleton models like SignBERT+,
ASL-Citizen 2,731-class benchmarks) are not comparable to a 5-10 sign, open-set, signer-independent
setting and are not used as targets. Nothing here should be called "state of the art".

**Selection rule:** if a complex variant does not beat a simpler one on held-out signers by more than
fold-to-fold noise, ship the simpler one. `recognition/ablate.py` implements every requested comparison;
on the synthetic data several simple models tie the dual-stream model, which says only that the synthetic
task is easy.

## Rejection, calibration, tiers (`recognition/openset.py`)

* `UNKNOWN` is a real output class trained on hard negatives (rest, random motion, hand entering,
  unsupported shapes, truncated signs, wrong-trajectory signs, non-sign).
* Scorers compared on validation: log-odds, max-prob, entropy, margin, energy, prototype distance. Probability-
  space scores saturate at exactly 1.0 (observed) so ties made thresholds impossible; log-odds does not saturate.
* Temperature is fit on validation signers; ECE, reliability and coverage-accuracy are reported.
* Thresholds come from validation only and bound the **Wilson upper confidence limit** of the bad-accept
  rate. Consequence, by design: with fewer than ~73 validation negatives a 5% target is unreachable and
  the policy refuses to show any sign. Tiers: `show` (present for confirmation), `retry`, `unknown`,
  `low_tracking` (quality gate, never a supported label).

## Segmentation (`recognition/segmenter.py`)

Palm-length-per-second motion energy (centroid speed and handshape change speed) with hysteresis, a
settle period, border ("entering") exclusion on the palm core, tolerance for short tracker dropouts, a
static-hold path, a hard duration cap, and an unarmed refractory state that prevents repeated predictions
from one sign. On synthetic streams: 0 duplicates and 0 spurious segments, but static holds shorter than
about 0.8 s and slow in-place handshape changes are the weak spots. Thresholds are starting points;
`recognition.replay.tune_segmenter` tunes them on validation streams.

## Data and evaluation rules

* Every split is by signer; `assert_no_leakage` rejects shared signers, sessions or identical geometry.
* `recognition/collect.py` builds a first-party corpus from the app's landmark export with mandatory
  consent text, verifier ID and conditions (lighting, distance, background, speed, occlusion, handedness,
  optional self-reported skin tone), and reports hard-test coverage gaps.
* Hyperparameters, temperature and thresholds never see the test signers. `evaluate.py` reads them once.

## Commands

```sh
python3 -m venv .runtime/venv && .runtime/venv/bin/pip install -r recognition/requirements.txt
.runtime/venv/bin/python -m unittest discover -s recognition -p "test_*.py" -t .
.runtime/venv/bin/python -m recognition.train --synthetic --out .runtime/runs/x            # pipeline check
.runtime/venv/bin/python -m recognition.ablate --synthetic --suite arch --folds 4 --out .runtime/ablate.json
.runtime/venv/bin/python -m recognition.benchmark --corpus my_corpus.json --out .runtime/bench
# Core ML export needs Python <= 3.12 + torch 2.7 (see requirements.txt)
.runtime/venv-coreml/bin/python -m recognition.export_coreml --run .runtime/runs/x --out ios/Signloop/Resources/SignEngine --corpus my_corpus.json
bash ios/scripts/test-core.sh                                                              # Swift parity (161 checks)
```

## Known limitations and open items

1. No real-signer evidence. The first real number requires a consented first-party corpus (or a research
   license decision for ASL-Citizen, which would not be shippable).
2. No iPhone measurements. Mac Core ML timings are in the benchmark; iPhone p50/p95 must be measured on
   devices with the Debug build (`SIGN_ENGINE_*` test gives a template).
3. Pod/Xcode build of the integration edits (`CameraTracker`, `SignloopCameraView`, podspec) was not run;
   the files parse, the pure engine files compile and pass, and TypeScript type-checks.
4. Hands-only input: body-relative signs are not distinguishable. Anchors are plumbed but not sourced.
5. The synthetic generator has 6 toy classes; its results say nothing about ASL difficulty.
6. `rotate` and `canonical_dominant` feature options exist in Python but the Swift port refuses models using
   them.
