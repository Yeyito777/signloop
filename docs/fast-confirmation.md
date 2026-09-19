# Faster accepted-sign display, calibrated separately

The learned model already consumes a temporal window. Requiring two matching
overlapping windows can hide a short sign even when the classifier correctly
accepts it. This change allows a qualifying **already accepted** estimate to
display after one result; weaker accepted results still need two.

## Selection used only original calibration data

`backend.research_confirmation` accepts only the SHA-pinned original V2 corpus.
It selects its **32 calibration clips / four participants**, re-extracting
landmarks and canned gestures at the current 24Hz tracking cadence. It never
selects test/additional clips or tunes model logits.

The simulator evaluates a fixed grid: no bypass, then score thresholds .95,
.90, .85, .80, .75, .70, .65, .60, .55, .50, .45. Maximize correctly displayed
calibration clips with zero wrong displayed clips; on ties prefer no bypass,
then the highest threshold. Only after selection was fixed was the previously
inspected 117-clip cohort replayed.

Selected **0.45**: calibration correct display 14/17 supported versus baseline
13/17, with 0/15 unsupported false displays and no wrong-known displays in
either case. Higher thresholds did not recover the extra clip.

**0.45 is a softmax score, not a calibrated probability or “high confidence.”**
This small calibration cohort is not a safety guarantee. The initial idea of a
high-confidence-only bypass did not improve coverage on this calibration set;
the selected modest threshold remains an experimental display policy.

## Preserved rejection and timing protections

- All 250 labels compete. Unsupported top labels stay unknown.
- Classifier score >.40, top-two gap >=.05, and NO articulation >=.075 remain
  unchanged. `unknown: true` always clears the display, even with a .99 score.
- Only HELLO / YES / NO / PLEASE / THANK_YOU enter this temporal path.
- Finite bounded scores, fresh observations/results, no-hand/gap resets,
  camera generations, one in-flight worker and no backlog remain enforced.
- Accepted score >=.45 displays immediately; accepted scores below it still
  need two matching results. A changed weak label clears the previous label
  rather than retaining misleading text.
- The independent single-hand ILY hold/score policy is unchanged.

## Development diagnostic, not a new holdout

The larger cohort was already inspected when confirmation delay was identified.
Its reuse below is a **development comparison**, not fresh validation.

| Supported label | Baseline two-result display | Selected faster display |
| --- | ---: | ---: |
| HELLO | 6/13 | 9/13 |
| YES | 8/13 | 10/13 |
| NO | 7/12 | 9/12 |
| PLEASE | 10/13 | 13/13 |
| THANK_YOU | 3/12 | 6/12 |
| ILY | 9/19 | 9/19 |
| **Total** | **43/82** | **56/82** |

Neither mode displayed a wrong word in supported clips. Both falsely displayed
PLEASE on **1/35 unsupported clips**. The remaining misses and false accept
are not fixed by this change. Face/body context, natural nonsigning, fresh
signers and real-phone performance still need validation.

Calibration median first correct display from **clip start** was 924ms in the
baseline and 739ms with the selected rule, excluding missed clips. Different
correctly detected subsets make this **not** a paired latency improvement or
camera-to-caption measurement.

## Reproduce locally

```sh
# Pinned MediaPipe/OpenCV research environment; original cached videos only:
python3 -m backend.research_confirmation --accept-research-license \
  --corpus path/to/corpus-v2.json --clips path/to/asl-citizen/clips \
  --model ios/Signloop/Resources/gesture_recognizer.task
```

Provision the generated fixture only to a disposable local simulator. Launch
`--signloop-live-replay --calibrate-fast-confirmation --benchmark-run=<id>`.
The native calibration entry rejects fixtures with non-calibration groups or
missing supported/unknown labels. Require `selection_feasible: true`.

For a diagnostic replay after freezing the result, `--fast-score=0.45` selects
the candidate and `--fast-score=baseline` forces the prior two-result policy.
Without that flag, the benchmark uses the actual app default.
Read exact run IDs; never treat an old result file as a fresh successful run.
Do not provision restricted research observations to a phone or provider.

Verified: 68 Python tests without skips, core Swift scheduling/fast-boundary
tests, existing native HTTP/DTW/tensor/articulation parity, six simulator UI tests
and signed iPhone build. A replay using the actual default (no threshold flag)
matched every count from the explicit .45 run. The native calibration entry
also rejected the non-calibration cohort in an intentional negative test.
