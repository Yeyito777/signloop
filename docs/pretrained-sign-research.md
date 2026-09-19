# Pretrained 250-word candidate — 2026-09-19

**Promising local research result, not yet enabled or validated on an iPhone.**
This is a real pretrained isolated-sign model, not prompted numeric guessing or
a relabeling of generic gestures.

## Source and provenance

- Mirror: [sign/kaggle-asl-signs-1st-place](https://huggingface.co/sign/kaggle-asl-signs-1st-place),
  pinned revision `d831c2f58cefbc5110dfbb91cc8e6eb516b4ccfc`.
- Credited original author: **hoyso48**,
  [1st place solution — inference](https://www.kaggle.com/code/hoyso48/1st-place-solution-inference).
- Original notebook inspected via Kaggle's public kernels API, not executed.
- Model: 11,242,036-byte float16 TFLite asset, SHA-256
  `f55a2bb1ebe6d1e912a98e31c6ef3f995c9ae261f408fe115f2008099d3f0bb7`.
- Vocabulary SHA-256:
  `1fe747c2f44c68dbb396947e35193c96d363f3dede0be8defa5e08546400bf5d`.
- Mirror model card declares **MIT**. However, the original author's
  `hoyso48/islr-models` Kaggle metadata reports **license Unknown**.
  That discrepancy is unresolved; do not describe redistribution rights as
  confirmed. No weights/vocabulary have been committed or bundled in the app.

## Input/output contract

Signature `serving_default(inputs) → outputs`.
Input is float32 `[time, 543, 3]`: face 0–467, left hand 468–488,
pose 489–521, right hand 522–542. Absent coordinates are NaN.
Output is **250 logits**, not probabilities.

The original model selects hands plus lip/nose/eye landmarks (not pose),
normalizes around a lip anchor with a missing-anchor fallback, and uses first/
second temporal differences. Its preprocessing is already inside the model.

This experiment is a deliberate **hands-only ablation**: existing 15 Hz
MediaPipe observations fill the hand slots; face/pose remain NaN. We do not
invent missing face/body observations. Mirroring metadata is canonicalized;
duplicate handedness uses highest confidence with a deterministic geometry
tie-break, not fabricated second-hand data.

All 250 logits compete. We do **not** renormalize only five desired words.
If the global winning class is outside HELLO/YES/NO/PLEASE/THANK_YOU, reject it.
Softmax scores are not calibrated sign probabilities. At least six frames,
hands in at least half the window, and hands in the last frame are required.

## Frozen rolling-window evaluation

Same local ASL Citizen V2 corpus and boundaries as the earlier
[streaming tests](recognition-streaming-results.md):

- 1,200 ms windows, 250 ms cadence, phases 0/83/166 ms.
- Two consecutive accepted decisions; unknown/no hands reset immediately.
- Simulated instantaneous inference responses, no network or real camera.
- Calibration: 32 clips / 4 signers; test: 29 clips / 9 other signers.
- Test clips were inspected in previous experiments: **not a fresh holdout**.
  Overlap with the pretrained model's training people/data has not been
  independently excluded.
- Three phases per clip are correlated, not separate recordings.

A fixed score/margin grid was selected on calibration only, maximizing correct
displayed runs with zero wrong displayed runs (including wrong-known guesses).
Frozen selection: **score > 0.40 and top-two score gap ≥ 0.05**.

| Split | Supported runs with correct display | Unsupported runs with false display | Wrong-known displayed runs |
| --- | ---: | ---: | ---: |
| Calibration | 34/51 | 0/45 | 0 |
| Diagnostic test | **32/42** | **0/45** | **0** |

Diagnostic correct display by label:
HELLO **5/9**, YES **4/6**, NO **8/9**, PLEASE **6/6**, THANK_YOU **9/12**.
The model produced a correct raw accepted estimate in 40/42 supported test runs;
confirmation and clip timing still suppress some.

This is stronger diagnostic coverage than either DTW variant, but not evidence
of general continuous-sign or accessibility-critical communication accuracy.
The correctly displayed subset has median first-display time 734 ms from
**clip start**, not annotated sign onset, and excludes missed signs and compute.

## Important negative probe

Replicating the first/middle/last tracked calibration pose into a stationary
19-frame window generated **96 synthetic frozen-pose probes**. With the frozen
policy, **3 were falsely accepted as NO**. These are not natural non-signing
recordings or a population false-positive estimate, but expose a real reason
not to declare the system finished or automatically enable it.

Motion/quality gating, natural nonsigning examples, fresh signers, phone
tracking, camera-to-display latency, and model-rights clarification remain.
No transcription backend or API key is involved in this candidate.

A subsequent [articulation-gate experiment](recognition-motion-guard.md) rejects
the stationary/noisy development probes without losing displayed coverage on
this diagnostic set. It is not a substitute for natural nonsigning validation.

## Reproduce locally

Use an isolated environment with `ai-edge-litert==2.2.0` and NumPy. Download
the pinned mirror assets into an ignored `.runtime` directory only after
reviewing provenance/terms; the evaluator checks both exact hashes.

```sh
python3 -m backend.research_pretrained path/to/corpus-v2.json \
  --model .runtime/model.tflite \
  --vocabulary .runtime/sign_to_prediction_index_map.json \
  --out .runtime/pretrained-report.json
python3 -m unittest backend.test_pretrained -v
```

The experiment makes **no network calls**. It never sends ASL Citizen data to a
model provider. Per-clip reports remain local/ignored, and only aggregates print.
The default app remains the offline ILY preview; this research module is not
registered with the runtime backend.

Nine new tests cover asset hashes, global-class competition, score/margin
rejection, calibration errors, tensor layout, absent landmarks, mirroring and
duplicate-order independence. All nine pass in the research environment; four
tensor tests explicitly skip when optional NumPy is absent. Native Swift
`LiveSignFilter` also matched all **452 events** in the diagnostic replay.
