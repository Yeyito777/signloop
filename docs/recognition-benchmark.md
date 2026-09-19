# Recognition benchmark: current baseline vs new engine

**Read this first: every number below is from a synthetic, non-ASL generator (`recognition/synthetic.py`).**
No licensed training data existed on the development machine and no iPhone was attached. These runs prove
that the pipeline (signer-disjoint splits, training, rejection, calibration, Core ML export, Swift parity)
works end to end and expose some mechanics. They are not evidence that the new engine recognizes real
signers better, and the near-perfect scores mostly say the toy task is easy. The real comparison is a
one-line rerun once a corpus exists:

```sh
python -m recognition.benchmark --corpus my_corpus.json --out .runtime/bench
```

## Setup

* 32 synthetic signers, 6 supported toy signs plus UNKNOWN negatives (rest, random motion, hand
  entering, unsupported shape, truncated sign, wrong-trajectory sign). Signer-disjoint 60/20/20 split.
  Test set: 252 clips from 6 signers that neither system trained or tuned on.
* Both systems use the same rule to choose a rejection threshold from the validation signers (Wilson
  upper bound of the bad-accept rate <= 5%). The baseline's own legacy rule (zero validation errors) is
  also reported.
* Baseline = `reference-dtw-v2`, the only in-repo landmark recognizer that can be trained on our corpus.
  The shipped ILY rule and the undistributed Kaggle weights are not comparable / not allowed.

## Headline table (same test set)

| System | Signer-independent known top-1 | Macro F1 | False-accept on unknown | ECE | p50 latency | p95 latency | Model size |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Current: reference-dtw-v2 | 0.028 (0.000 under its legacy rule) | 0.129 | 0.019 (2/108) | 0.256 (similarity, not a probability) | 1176 ms Python, host CPU; Swift port not timed | 1293 ms | 0 (reference set) |
| New: dual:concat (fp16 Core ML) | 1.000 | 1.000 | 0.000 (0/108) | 0.000 (0.042 uncalibrated) | 0.89 ms CPU / 0.51 ms all units, Mac | 1.0 ms / 0.67 ms, Mac | 1.0 MB (0.53 MB int8) |
| New: gru | 1.000 | 1.000 | 0.000 | 0.000 | not exportable | not exportable | n/a |

* **iPhone latency: not measured.** The Latency columns for the new model are Mac (Apple M4) Core ML
  numbers and exclude MediaPipe and feature extraction. Swift end-to-end (features into Core ML) took
  1.3 to 7 ms per call on the Mac, the first being a cold call.
* Zero false accepts in 108 unknown test clips is compatible with a true rate up to about 3.4% (Wilson
  95% upper bound).
* The baseline's low score is partly its strict threshold protocol (it accepted almost nothing) and
  partly its Python cost; it is not a claim about DTW on real signs, where it recognized 9/30 in the earlier
  real-recording test (see `recognition-baseline-results.md`).
* GRU cannot be exported through `torch.export` to Core ML (unsupported op). That removes it from
  consideration for shipping regardless of accuracy.
* Core ML fp16 and int8 packages agree with torch fp32 on 100% of 64 argmaxes (max logit diff 0.012 and
  0.014). Parity was also checked from Swift (its own features into Core ML) on 4 clips.

### Confusion matrix (best new model, test signers)

| truth \ pred | S_FIST_BOB | S_FLAT_STATIC | S_FLAT_WAVE | S_OPEN_CLOSE | S_POINT_CIRCLE | S_Y_STATIC | UNKNOWN |
|---|---|---|---|---|---|---|---|
| S_FIST_BOB | 24 | 0 | 0 | 0 | 0 | 0 | 0 |
| S_FLAT_STATIC | 0 | 24 | 0 | 0 | 0 | 0 | 0 |
| S_FLAT_WAVE | 0 | 0 | 24 | 0 | 0 | 0 | 0 |
| S_OPEN_CLOSE | 0 | 0 | 0 | 24 | 0 | 0 | 0 |
| S_POINT_CIRCLE | 0 | 0 | 0 | 0 | 24 | 0 | 0 |
| S_Y_STATIC | 0 | 0 | 0 | 0 | 0 | 24 | 0 |
| UNKNOWN | 0 | 0 | 0 | 0 | 0 | 0 | 108 |

Baseline (`reference-dtw-v2`) on the same clips: 4/144 known signs shown correctly, 106/108 unknowns
rejected, 2/108 falsely shown.

## Architecture ablation (4 signer folds, mean ± std, synthetic)

Raw top-1 is argmax over known classes before any rejection; "after rejection" counts a rejected known
sign as wrong. "Stress" applies tracking failures (jitter, 12% burst hand loss, 15% dropped frames, joint
outliers) to the test signers only.

| Variant | Params | Raw top-1 | Top-1 after rejection | Macro F1 | FAR | ECE | Stress raw top-1 | Stress FAR |
|---|---|---|---|---|---|---|---|---|
| single_frame | 60,703 | 0.831±0.004 | 0.048±0.041 | 0.146±0.049 | 0.015±0.013 | 0.096±0.017 | 0.821±0.015 | 0.007±0.005 |
| mlp | 337,939 | 0.999±0.002 | 0.961±0.015 | 0.973±0.010 | 0.017±0.012 | 0.015±0.003 | 0.986±0.006 | 0.008±0.008 |
| gru | 180,947 | 1.000±0.000 | 0.981±0.019 | 0.980±0.010 | 0.025±0.021 | 0.009±0.006 | 0.996±0.004 | 0.020±0.016 |
| tcn | 236,243 | 1.000±0.000 | 0.981±0.019 | 0.985±0.007 | 0.014±0.009 | 0.009±0.004 | 0.997±0.002 | 0.007±0.002 |
| transformer | 224,915 | 0.998±0.004 | 0.959±0.017 | 0.971±0.009 | 0.017±0.004 | 0.021±0.007 | 0.978±0.015 | 0.010±0.005 |
| stgcn | 229,105 | 0.826±0.005 | 0.129±0.075 | 0.237±0.077 | 0.015±0.007 | 0.046±0.006 | 0.832±0.016 | 0.006±0.007 |
| dual:concat | 425,089 | 0.999±0.002 | 0.980±0.018 | 0.984±0.010 | 0.014±0.015 | 0.007±0.006 | 0.995±0.007 | 0.010±0.011 |
| dual:gated | 431,713 | 0.999±0.002 | 0.980±0.018 | 0.984±0.009 | 0.014±0.012 | 0.009±0.005 | 0.981±0.005 | 0.010±0.006 |
| dual:attention | 449,953 | 0.997±0.005 | 0.978±0.023 | 0.983±0.013 | 0.014±0.009 | 0.007±0.003 | 0.980±0.023 | 0.011±0.010 |

What this does and does not show:

* **Temporal beats single-frame, by construction.** `single_frame` and `stgcn` (no trajectory input) sit at
  ~0.83 because two classes differ only by motion. That validates the pipeline; it is not a finding
  about real ASL.
* **Fusion variants are indistinguishable** (differences well inside the fold std), so per the selection rule
  the simplest (`concat`) wins over `gated` and `attention`.
* **The dual-stream model did not beat simpler temporal models** (mlp, tcn, transformer) on this data.
  The rule says ship the simpler model unless real data shows otherwise. tcn is the natural simple
  candidate (exports to Core ML, 236k params).
* After-rejection top-1 is below raw top-1 for every model: the conservative threshold rule
  gives up some known signs to hold the false-accept rate down. That is the intended trade.

## Ablations not yet reported

`recognition.ablate --suite features|reject|aug` (derivatives, shape-only vs trajectory, angle features,
rotation normalization, background class vs threshold-only, and per-augmentation removal) is implemented
and was started but had not finished when this was written. Rerun it on real data; its synthetic outputs
would not change any decision.

## What would make this a real result

1. A consented first-party corpus via `recognition/collect.py` with enough signers that validation holds
   at least 73 negatives (otherwise the policy correctly refuses to show any sign).
2. Body anchors from Apple Vision (face/shoulders), then the anchors-on vs off ablation.
3. iPhone p50/p95 with the Debug build, on more than one device generation.
4. A fresh held-out signer set, untouched until the frozen decision rule is scored once.
