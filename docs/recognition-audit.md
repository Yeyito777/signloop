# Recognition engine audit (Phase 1)

Scope: what the recognizer in this repo actually does today, traced from camera to
the prediction the user sees. Based on reading the code and the existing
`docs/` evaluations; nothing here was measured on a device by the author.

## Path, as built

```
AVCaptureSession 1280x720 BGRA, 30fps requested, physically rotated/mirrored
  -> CaptureFreshness / CaptureCadence (24Hz deadline pacing, stale-frame guards)
  -> MediaPipe GestureRecognizer 0.10.21 (video mode, 2 hands, 0.55 thresholds)
       -> 21 landmarks x (x,y,z) per hand, handedness label + handedness score
       -> canned gesture label + score (7 generic classes)
  -> LandmarkFrame {timestampMS, hands[], imageAspectRatio, mirrored}
  -> TemporalBuffer (<=2s / 90 frames, RAM only)
  -> ONE OF THREE CONSUMERS
```

| Consumer | Where | Reaches the mobile app? |
| --- | --- | --- |
| **ILY rule** (`LocalGestureFilter`): canned label `ILoveYou`, score >= 0.85, lead >= 0.2, 3 frames and >= 150 ms | `Recognition.swift`, `CameraTracker.swift` | **Yes. This is the only shipped recognizer.** |
| Kaggle-ISLR 250-word TFLite (`PretrainedSignEngine`) | `ios/Signloop/*Pretrained*`, `LocalSignRecognition` | Standalone scanner, DEBUG only, weights sideloaded, rights unresolved |
| Reference DTW (`TemporalReferenceMatcher`, `backend/matcher.py`) | Swift + Python, parity tested | No. No references are bundled. |

ASL-Citizen ST-GCN / I3D checkpoints are Python-only research baselines.

## Answers to the audit questions

- **Frames to native code:** in-process, never through JS. `onSign` carries a label string only.
- **Features extracted:** MediaPipe hand landmarks only. No pose, face, torso, shoulder
  or lip anchors. There is no per-landmark visibility; a hand is present or absent.
- **Single-frame vs temporal:** the shipped ILY rule is single-frame plus a 3-frame
  persistence check. The research paths are temporal (1.2 s window resampled to 15 Hz;
  DTW resamples to 24 steps).
- **Preprocessing:** aspect-ratio and mirror correction, wrist-centering, palm-length
  scale (wrist to middle MCP). `TrackedHand.normalized` is 2D-scaled with raw z.
  No rotation handling, no velocity or acceleration, no joint angles, no bone vectors.
- **Model architecture:** none of ours. Canned MediaPipe classifier; a third-party
  1st-place Kaggle model (hands-only ablation with face/pose set to NaN); DTW.
- **Training code / datasets:** none. The repo has no trainer. ASL-Citizen import
  exists (`backend/research_data.py`) but the corpus is not on this machine and its
  license is noncommercial research only.
- **Inference format:** TFLite via the interpreter inside MediaPipe. No Core ML.
- **Smoothing:** two consecutive equal accepts (`LiveSignFilter`); overlapping 1.2 s
  windows every 250 ms, so consecutive decisions are not independent evidence.
- **Confidence:** max softmax over 250 logits, thresholds 0.40 and lead 0.05 chosen on
  a 4-signer calibration set. Not calibrated; `docs/` says so. DTW uses `exp(-distance)`.
- **Missing landmarks:** whole-window gates (>= 6 frames, hands in >= 50 % of frames
  and in the last frame, gap > 200 ms resets). No masks, no interpolation, no
  dropout training. Absent joints become NaN and are handled inside the third-party model.
- **Left/right:** handedness label used as a slot; swapped when unmirrored; duplicate
  same-side detections resolved by score. `backend/hand_tracking.py` adds geometric association.
- **Unsupported gestures forced into a class?** ILY rule: no (rejects anything else).
  Kaggle model: 250-way softmax, reject when the winner is outside the five words,
  which is reasonable. But a hand-written NO-only articulation gate was needed after
  3/96 frozen-pose probes were accepted as NO, i.e. rejection is patched rather than learned.
- **Segmentation:** none. The rolling window fires every 250 ms whether or not a
  sign was attempted. Hand entering the frame is not excluded. There is no
  repeated-sign suppression except "held label does not recaption" in the UI.
- **Latency:** only Mac/simulator numbers (about 5 ms model). No iPhone camera-to-prediction
  measurement exists in the repo. The Python ST-GCN was 25 ms on a Mac GPU excluding tracking.
- **Evaluation:** the best held-out numbers are 14 to 42 supported clips from 9 to 11
  signers, three correlated phases each, on a cohort that had already been inspected.
  Whole-clip hybrid ST-GCN accepted 47/72; causal streaming displayed 14/72.

## Diagnosis

1. **The real bottleneck is not the classifier, it is the interface.** Isolated-sign
   models score 54-65 % on whole clips and 19-25 % when fed causal rolling windows.
   Nothing segments the sign, so the classifier sees the wrong span most of the time.
2. **Nothing is learned in our own pipeline.** We adapt third-party or reference
   systems whose training data we cannot ship, and every rejection rule is hand-tuned on tiny sets.
3. **Rejection has almost no evidence behind it.** Unknown examples in every prior
   test are *other ASL signs*, not rest, fidgeting, transitions or entering hands.
   Reported false-accept rates of 0/15 or 0/45 are consistent with 5 to 20 percent true rates.
4. **Hands-only input loses PLEASE / THANK_YOU / many signs** whose meaning is location
   on the face or chest. Hand-only trajectory can only be relative to the hand's own start.
5. **The test sets are used up.** They were inspected in earlier iterations, and
   the previous "streaming" numbers are correlated triples of the same clips.

## What this implies for the redesign

- Add a segmenter (IDLE -> POSSIBLE -> IN_PROGRESS -> COMPLETE -> PREDICTION) so the
  classifier receives one attempted sign, duration-normalized, and predictions fire once.
- Own the model: a small skeleton-aware temporal network trained on landmark sequences
  under signer-disjoint splits, with a real hard-negative class and calibrated rejection.
- Keep face/torso anchors optional in the feature schema; measure their value with
  an ablation instead of assuming it.
- Make data provenance a first-class property (`source`, `license`, `redistribution`)
  so nothing unlicensed can reach an app build.

## Blockers found in this environment

- No training data on this machine (`.runtime/` absent). ASL-Citizen use needs the
  user to accept its research-only license, and models trained on it are not
  shippable in the app.
- No iPhone is attached, so on-device latency and camera-level accuracy cannot be
  measured from here. Only simulator/Mac Core ML timings are possible.
