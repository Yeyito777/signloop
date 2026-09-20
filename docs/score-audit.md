# Vocabulary-size scoring audit

Build 16 changes the standalone scanner's score inspector, not the alphabet
model or teammate Expo app. The private 32-word bank is unchanged.

## Finding

Word scores never used softmax or division by the number of classes.
Each label's distance is the minimum temporal match cost over **that label's**
training references, plus its optional anatomical penalty. The old UI mapped
distance to `100 * exp(-distance / 0.08)` and displayed a percentage. The scale
0.08 was arbitrary: it did not estimate correctness or confidence.

Controlled replay uses identical frames, schedules, window length, rule weight,
and shared references. Taking the first 16 labels of the current 32-word bank:

- 74 existing validation clips, including unsupported examples.
- All 11,008 original-label score entries exactly equal with 16 versus 32
  labels (5,360 measured distances; the rest unavailable).
- 195/335 measurable events change winner when the other labels are introduced.
  Many of these clips are signs outside the first 16, so this is **not** an
  error rate.
- On just the original 16 signs: 29 window winners change; most-frequent
  per-clip correctness falls from 22/32 to 18/32. This is real competition,
  not a reduction of the existing labels' absolute scores.
- Median best distance across all measurable events in the 32-word replay is
  0.0787, which the old arbitrary transform rendered as 37.4%.

The prior installed 16-word bank also used rule weight 0.1 versus 0 for the
32-word bank. The controlled audit holds this constant at 0 to isolate vocabulary
size. All 75 original training references are preserved exactly in the expansion.

These are already-inspected development cohorts, not new live-phone or
held-out-signer accuracy measurements. This change does not improve the
classifier by increasing its apparent confidence.

## Fix

Settings → **Show match scores** opens a ranked **closest three** inspector.
**All 32** expands it to every candidate. It displays actual match distances
(`0` is identical feature geometry, lower is closer), not confidence percentages.
Missing observations remain dashes, and the closest result is explicitly not
confirmed. No forced 100% winner, normalization over competing labels, arbitrary
temperature sharpening, or hidden removal of difficult signs.

The temporal search now reuses dynamic-programming row buffers and abandons
paths only when their nonnegative accumulated cost already exceeds the best
reference for the **same label**. Never use the global winning sign as this
bound: doing so would corrupt the other labels' scores and create exactly the
vocabulary-dependent failure this audit guards against. Mirrored and direct
paths share only a same-label bound. All labels remain evaluated.

## Reproduce

```sh
mkdir -p .runtime
swiftc -O -parse-as-library \
  ios/Signloop/Skeleton.swift ios/Signloop/BasicSignMatcher.swift \
  ios/Tests/BasicSignReplay.swift -o .runtime/replay
python3 -m backend.score_audit \
  --replay .runtime/replay \
  --bank ../vocabulary-32/.runtime/demo-live/basic-references-packed.json \
  --clips ../vocabulary-32/.runtime/demo-live/val.json \
  --out .runtime/score-audit
python3 -m unittest backend.test_score_audit -v
```

`BasicSignReplay --scores` emits per-label distances from the actual native
matcher. Keep these reports and reference banks private under `.runtime`.
No videos are downloaded, no camera observations uploaded or recorded.

## Verification

- Exact pre/post-optimization equality of every scheduled winner, distance,
  margin and per-label score on 74 validation plus 106 existing test clips.
  This covers 5,895 scheduled events and 51,360 score entries (25,856 measured,
  the remainder unavailable). No classifier threshold or reference was tuned.
- Three alternating baseline/optimized Mac replay runs after builds finished:
  median 74-clip matching time **9.68 s → 7.77 s**, approximately **20% less
  matching time** (1.25× throughput). This is desktop native matching only,
  not an end-to-end live iPhone latency measurement.
- 55 synthetic matcher/real async-adapter invariants, including populated
  16→32 expansion, same-label search bounds, reference order, stable display
  ordering and missing evidence. Core tests passed.
- 108 Python tests passed, including deliberate score-dilution and scheduling
  regressions in the new audit tests.
- Final 13 simulator UI tests passed, including Top 3/All switching, persistence,
  score panel at accessibility text sizes and existing spelling controls.
  Release build 16 passed signed-device compilation and signature verification.
  Source/app credential scan passed; private reference bank is not bundled.

The signed build is ready for private device installation; this audit does not
claim that the phone was updated or that live recognition accuracy improved.
