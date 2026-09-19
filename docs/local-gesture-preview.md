# Offline ILY handshape preview — work toward real-time recognition

The app now uses MediaPipe Gesture Recognizer locally instead of relying on a
cloud round trip for every possible label. **Only its `ILoveYou` handshape maps
to `I_LOVE_YOU`.** Other canned classes are not ASL words: a thumbs-up is not YES,
a still open palm is not HELLO, and a closed fist is not a signed YES.

This is a limited single-hand preview, **not a replacement for the project's
multi-sign accuracy goal** and not validated ASL translation.

## Model and policy

- MediaPipe Tasks 0.10.21; official Gesture Recognizer float16 **version 1**.
- Download:
  `https://storage.googleapis.com/mediapipe-models/gesture_recognizer/gesture_recognizer/float16/1/gesture_recognizer.task`
- SHA-256:
  `97952348cf6a6a4915c2ea1496b4b37ebabc50cbbf80571435643c455f2b0482`.
- [Official task documentation](https://developers.google.com/edge/mediapipe/solutions/vision/gesture_recognizer).
- [Model card](https://storage.googleapis.com/mediapipe-assets/gesture_recognizer/model_card_hand_gesture_classification_with_faireness_2022.pdf).
  The model card explicitly excludes motion-based, compound two-hand gestures
  and sign-language translation from intended applications. It also warns that
  in-the-wild phone conditions are not validated.
- The bundle includes hand detection/tracking and returns the same 21 joints per
  hand used by the overlay. No second independent hand-tracking pipeline is run.
- Exactly one hand; top class ILoveYou with score >=0.85 and lead >=0.2.
  Scores are model outputs, not calibrated ASL correctness probabilities.
- At least three estimates spanning >=150 ms; gaps >150 ms reset evidence.
  Unsupported/uncertain input clears immediately, not after a sentence timeout.
- Camera pauses/flips reset local evidence; a 400 ms freshness check runs on the
  250 ms UI timer, so a stalled sign clears within about 650 ms.

Cloud analysis is **off by default**. The optional settings toggle retains the
unvalidated Jev path for developers and discloses uploads. Provider keys stay on
the backend. The local preview has no networking, recording or training workflow.

## Real-video check (not phone validation)

Frozen model and policy; no training or threshold search on this evaluation.
ASL Citizen was used only for local noncommercial research under its restrictive
license. Neither clips, frame outputs nor landmark references are committed or
bundled in the phone app. The shipped model is Google's pre-existing bundle, not
a model trained on the restricted dataset.

- Positive selection: one official-test ILOVEYOU clip per signer, sorted by file
  hash, **11 clips / 11 signers**.
- Negatives: 74 distinct other-sign clips from the previous research test corpora.
  No negatives removed for tracking failures. These are other ASL signs, not a
  comprehensive everyday nonsigning/motion dataset.
- Mirrored, fixed center <=3 seconds per clip, sampled around 15 Hz. A clip is
  detected if any contiguous interval satisfies the fixed policy.
- **7/11 positive clips detected (63.6%)**; **0/74 negative clips falsely accepted**.
- This is modest recall. Small-sample zero false accepts is not a guarantee.
  Overlap with Google's undisclosed training examples cannot be independently
  ruled out; this is not a claim of independently verified training-set exclusion.
- The actual Swift filter agreed with the Python policy on **3,205 real-model
  frames across all 85 clips**. This checks shipping decision logic, not iOS model
  inference equivalence or camera-to-display latency.
- Desktop Python model-call mean was **122.2 ms**, including hand/gesture inference,
  under concurrent development load. Do not call this phone performance.

## Native SDK smoke/performance probe

A DEBUG-only `--signloop-benchmark` launch path:

- Never opens the camera or a network connection.
- Reads an explicitly provisioned `Documents/gesture-benchmark.jpg`.
- Runs the same native recognizer configuration over that static image 35 times,
  with five warmup calls.
- Writes **metrics only** to `Documents/gesture-benchmark-result.json`, including a
  caller-supplied `--benchmark-run=...` identifier to reject stale results.
- Normal app launches do not run this or save metrics/images.

On a disposable iOS 26.3 simulator on the Mac, the official MediaPipe
[`thumb_up.jpg`](https://storage.googleapis.com/mediapipe-assets/thumb_up.jpg)
fixture produced hands in 35/35 calls and **zero ILY acceptances**.
Mean inference: **20.1 ms**, p95 **20.9 ms**, model setup **79.8 ms**.
This is a repeated-image **simulator** probe, not iPhone or live ASL validation.

## Reproduce

Research data/outputs must stay local and under ignored `.runtime/`; read the
[ASL Citizen restrictions](recognition-evaluation.md) before downloading.

```sh
# Requires the earlier corpus.json + corpus-v2.json and their cached clips.
# Run from the checkout containing the research Python environment, or use its
# explicit interpreter path from another task checkout.
.runtime/research-venv/bin/python -m backend.research_static \
  --accept-research-license --dataset-dir .runtime/asl-citizen \
  --model ios/Signloop/Resources/gesture_recognizer.task

swiftc -parse-as-library ios/Signloop/Recognition.swift \
  ios/Tests/LocalGestureReplay.swift -o .runtime/local-gesture-replay
.runtime/local-gesture-replay .runtime/static-evaluation/replay.json
bash ios/scripts/test-core.sh
scripts/dev/signlooptest . backend
```

Remaining requirements: actual iPhone latency/thermal/load checks, consenting
live signers, real transitions/nonsigning negatives, and reliable recognition of
the other supported words. Do not mark the overall project complete based on
this single static handshape.

## UI regression coverage

Five XCUITest cases passed on a disposable iOS 26.3 simulator: declining the real
Camera permission prompt and finding recovery controls; overlay preference
persistence; pause/resume without a backend; explicit cloud opt-in/off; and
reachable main controls at accessibility-extra-large text size. These tests skip
physical phones so XCTest attachments cannot record a real camera feed.

```sh
xcodebuild -project ios/Signloop.xcodeproj -scheme Signloop \
  -destination 'platform=iOS Simulator,id=YOUR_DISPOSABLE_SIMULATOR_UUID' \
  -derivedDataPath .runtime/ui-build CODE_SIGNING_ALLOWED=NO test
```

This is UI regression coverage with camera permission denied, not validation of
live overlay alignment or signing usability on a phone. Automated tests corrected
their own switch targeting to operate native controls inside SwiftUI rows.
