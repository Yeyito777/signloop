# Stationary-hand rejection experiment

The pretrained hands-only model sometimes labels a stationary hand as NO.
Increasing global confidence can suppress useful signs too, so this experiment
adds a **rejection-only articulation check for NO**, not another sign classifier.
All other labels keep the previous 250-class score policy.

## Feature and frozen policy

- Average thumb-tip to index/middle-tip XY distance, divided by wrist-to-middle
  knuckle distance. Correct X by image aspect ratio.
- Per handedness, require six contiguous observations, no duplicate side,
  no missing hand, no >150 ms gap or aspect/mirroring transition.
- Three-frame median, then maximum-minus-minimum aperture within each segment.
  Take the largest segment variation. Do not interpolate across tracking gaps.
- Translation, uniform scale and image reflection cancel. This does **not**
  guarantee invariance to out-of-plane rotation or identity swaps.
- Existing global 250-class score **>0.40**, top-two gap **≥0.05** remain frozen.
- For an otherwise accepted NO, require aperture variation **≥0.075 palm units**.
  Failure returns unknown with `insufficient_articulation`; it never substitutes
  another label or promotes an uncertain result.

The fixed threshold grid was 0, .025, .05, .075, .1, .15, .2, .3, .4, .6, 1, 2,
and infinity (reject all NO). Calibration maximized correct displayed runs
subject to zero wrong displayed runs and zero accepted synthetic probes, then
chose the smallest eligible threshold. Only calibration data was accessed before
selection. Test clips were already inspected in earlier research and are **not
a fresh holdout**.

## Local results

Same 1,200 ms / 250 ms / three-phase rolling protocol as the pretrained baseline,
two consecutive accepted decisions, simulated instantaneous responses:

| Measurement | Before | With motion gate |
| --- | ---: | ---: |
| Calibration correctly displayed supported runs | 34/51 | 34/51 |
| Diagnostic test correctly displayed supported runs | 32/42 | 32/42 |
| Diagnostic wrong displayed runs | 0/87 | 0/87 |
| Synthetic stationary/noisy windows accepted | 12/384 | 0/384 |

The 384 probes are first/middle/last poses from 32 calibration clips, each frozen
into 19 frames with independent fixed-seed XY noise bounded by 0%, 0.5%, 1%, or
2% of palm scale. Each noise group has 96 windows; all are rejected after gating.
The noiseless group reproduces the original three false accepts.

These are **synthetic development probes**, not natural nonsigning recordings,
independent people, a population false-positive rate, or proof the defect cannot
recur. Three temporal phases from a clip are correlated. Natural fidgeting,
occlusion, close-up tracking, same-side identity replacement, live latency, fresh
signers and physical-phone behavior still need testing.

## Native behavior and reproduction

`PretrainedSignEngine.classify` applies the frozen gate after the original model
output policy; raw `policy.decode` remains the v1 logit contract for existing
runtime-parity benchmarks. Guarded classifications identify
`kaggle-islr-250-hands-motion-research-v2`.

**The default camera has not been switched to this model.** No weights,
restricted research data or provider keys are bundled. Weight distribution
rights remain unresolved; see [pretrained research](pretrained-sign-research.md).

```sh
# Isolated LiteRT/NumPy environment, local research data and pinned assets:
python3 -m backend.research_motion path/to/corpus-v2.json \
  --model path/to/model.tflite \
  --vocabulary path/to/sign_to_prediction_index_map.json \
  --out .runtime/motion-report.json

python3 -m unittest backend.test_motion -v
python3 -m backend.test_motion_native
# Optional local-only real-window feature parity; temporary fixture is deleted:
python3 -m backend.test_motion_native --corpus path/to/corpus-v2.json
```

The eight mechanical tests cover rigid translation, reflection/scale, aspect
ratio, missing/duplicate hands, gaps, one-frame jitter, degenerate palms,
rejection-only semantics, seeded probe construction and infeasible calibration.
Native parity compares the metric to 0.00002 absolute tolerance and exact
rejection/model/reason preservation using the same Float inputs.

Verified locally: **61 Python tests passed** in the research environment with
no skips; Swift motion parity passed **22 synthetic windows**, then **900
combined synthetic/real whole-clip and rolling windows**. Existing native HTTP,
124-case DTW, 117-case pretrained tensor/logit tests and core checks also passed.
Unsigned iPhone build succeeded. No new physical-phone installation or live
accuracy validation was performed for this change.
