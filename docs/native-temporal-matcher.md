# Native temporal matcher — 2026-09-19

`ios/Signloop/TemporalReferenceMatcher.swift` ports the Python
`reference-dtw-v2` computation into Swift. `NativeTemporalClassifier` implements
the app's replaceable `SignClassifier` protocol.

**This is infrastructure, not a newly supported ASL vocabulary.** It is compiled
into the app but not selected by its UI. No reference corpus, research recording,
API key or trained reference asset is bundled. The offline ILY preview remains
the only default local sign estimate.

## What runs locally

- Aspect/mirror correction and temporal association of up to two hands.
- Duplicate-detection removal, 300 ms association expiry, ambiguous-ID rejection.
- Wrist-relative handshape, wrist motion and relative two-hand placement.
- At most 24 time samples and banded dynamic time warping against references.
- Nearest reference per label, distance/margin rejection, quality diagnostics.
- Scores are `exp(-distance)`, **not calibrated probabilities**.

All intermediate state belongs to the classification call. The engine performs
no network, filesystem, recording, or API operations. References are immutable
precomputed features, not a camera history. Run matching on a worker rather than
the UI/capture queue.

Inputs are bounded to 90 frames / three seconds / two hands / 21 finite joints.
Native configuration additionally limits references to 256, checks unique IDs,
requires at least two supported labels, and rejects unusable references.

## Verification

The test compiles the actual app math and protocol adapter with `swiftc -O`.
It compares candidate distances (absolute tolerance 0.00002 for Float camera
coordinates versus Python precision), rejection reasons, accepted labels, and
adapter similarities against the Python V2 implementation.

- **124 synthetic queries**, including 100 deterministically perturbed windows.
  These are artificial geometry, not ASL.
- **233 local research queries**: all 88 V2 corpus clips plus 145 causal rolling
  windows from its test clips. Some whole clips are training self-matches:
  **this is implementation parity, not an accuracy experiment**.
- Native-only configuration checks cover invalid/nonfinite thresholds, empty,
  duplicate and unusable references, exact-distance ambiguity and ordering.
- Native in-memory NaN/Infinity input checks supplement valid-JSON fixtures.
- The asynchronous `SignClassifier` adapter is exercised, not just the math.

Optimized desktop timing is printed separately; it does not include hand-model
inference or camera/UI work and must not be described as iPhone latency.
The measured 233-query run averaged **0.641 ms**, with **1.433 ms p95**, on this
development Mac (including short/no-hand windows). This is not directly
comparable with the earlier Python whole-clip timing.
The earlier Python V2 accuracy and rolling-window limitations still apply:
porting the same algorithm does not improve accuracy by itself.

## Reproduce

From the repository root, with no API key or downloaded dataset:

```sh
scripts/dev/signlooptest . native
# Or just the temporal engine:
python3 -m backend.test_temporal_native
```

Optional local research parity:

```sh
python3 -m backend.test_temporal_native \
  --corpus path/to/corpus-v2.json \
  --calibration-report path/to/report-v2.json
```

This verifies corpus/model binding before use. Temporary local fixtures are
removed on normal completion/error. No identifiers or observations are printed,
uploaded or copied into the app. Existing research-data restrictions apply.

## Before enabling multi-sign inference

We still need a reference set licensed/consented for on-phone distribution,
human validation, rejection calibrated on rolling windows, a latest-window
worker with no stale-result queue, and continuous held-out phone testing.
The current research corpus must not be distributed in the demo app.
See [streaming diagnosis](recognition-streaming-results.md) for why simply
running the old confirmation rule faster is insufficient.
