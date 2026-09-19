# Signloop

Hack the North · limited-vocabulary ASL-to-English prototype.

## One-screen offline handshape preview

Open the app, put one hand in view, and see the **current possible sign** update
automatically over the full-screen camera. No settings workflow, reference
capture, saving, or Analyze button. Pause/flip stay on the camera; the top-right
settings button controls hand joints, joint numbers and tracking stats.

**The default offline preview currently recognizes only the ILY (“I love you”)
handshape without extra model assets.** Extend thumb, index and pinky; fold middle
and ring. A private Debug build with verified pretrained assets automatically
enables the [five-sign offline research mode](docs/live-offline.md):
HELLO, YES, NO, PLEASE and THANK_YOU. It requires no Mac connection, network or API key and does not
upload images or landmarks. Thumbs-up is never relabeled as ASL YES.

MediaPipe's pretrained Gesture Recognizer supplies both real landmarks and
handshape estimates. This is not a general ASL model. See
[the local evaluation and limitations](docs/local-gesture-preview.md).

The camera screen is now **offline only**; the cloud toggle and automatic
backend calls have been removed. Legacy [backend research tools](docs/backend.md)
remain separate. The five-sign weights are not bundled or publicly distributed
while their provenance/rights are clarified. Live iPhone and fresh-signer
accuracy validation remain open project goals.

## Local reference-matching experiment

The zero-shot path has not demonstrated reliable recognition. A separate
**nearest-reference + dynamic time warping** backend now supports developer-side
labeled recordings, signer-disjoint calibration/testing, and inspectable distance
and rejection diagnostics, without any model API calls. It is opt-in, not an
automatic replacement for the deployed classifier.

See [local recognition evaluation](docs/recognition-evaluation.md) for replay,
dataset restrictions, results and the remaining phone-validation requirements.
No research recordings or derived landmark references are distributed in this repo.

The [native Swift temporal engine](docs/native-temporal-matcher.md) now implements
the same V2 matcher without a server. It is parity-tested but **not enabled in the
camera UI**: distributable references and live rejection validation are still needed.

A [pretrained 250-word candidate](docs/pretrained-sign-research.md) now recognizes
all five target words in local rolling-window research. A calibrated articulation
gate rejects the synthetic stationary-NO failures. Natural nonsigning behavior,
phone validation and model provenance remain unresolved.

The [native runtime probe](docs/native-pretrained-runtime.md) matches Python
model outputs and coexists with MediaPipe on the iOS simulator. It is a
developer-only test entry. The separate live worker now uses the same native
engine when exact private Debug assets are present; the screen clearly identifies
that research mode instead of claiming it is available in every build.

**Latest larger frozen check:** 43/82 additional supported recordings produced a
correct displayed sign; 1/35 unsupported recordings falsely displayed PLEASE.
[Full protocol and limitations](docs/frozen-additional-evaluation.md).
This is still a research prototype; good live accuracy has not been established.

A separately calibrated [faster confirmation rule](docs/fast-confirmation.md)
raises displayed coverage to **56/82 on that now-inspected development cohort**,
with the same 1/35 unsupported false display. This is not a new holdout result.

## Parallel development

Use a separate branch/checkout per task while keeping `yeyito` available:

```sh
scripts/dev/setup-worktrees
scripts/dev/create-worktree camera-polish
scripts/dev/signlooptest camera-polish
# After merging your task:
scripts/dev/clean-worktree camera-polish
```

See [the worktree guide](docs/worktrees.md) for build/open commands, dependency
isolation, safety checks, and the create/clean smoke test.

## Developer MVP: real on-device hand tracking

Native iPhone app with **Google MediaPipe Gesture Recognizer**, including its
real hand-landmark model, not simulated joints. Tracking and the ILY preview work
locally. Only optional cloud inference needs the backend; provider API keys are
never embedded in the phone.

- Live front/rear camera, portrait orientation and mirrored selfie preview.
- Up to two hands, 21 joints per hand and an optional colored skeleton.
- Camera-first Material-inspired design with a single current-sign overlay.
- Persistent overlay preferences in the top-right settings sheet.
- Pause/resume, permission handling, background suspension.
- Two-second memory buffer; optional cloud inference uses the latest 1.2 seconds.
- On-device ILY handshape scoring, minimum 150 ms evidence, immediate rejection
  clearing and a stalled-camera watchdog. Model scores are not sign probabilities.
- Replaceable classifier protocol. The default unconfigured classifier returns
  `unknown`. Jev uses built-in criteria, not saved user examples. Uncertain or
  unsupported inputs show Unknown; this is **not validated ASL translation**.

### Build

Requires macOS, Xcode (iOS 17+ SDK), and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
cd ios
bash scripts/bootstrap.sh
open Signloop.xcodeproj
```

Choose your Apple development team in Signing & Capabilities, select your connected iPhone,
and Run. Trust the Mac, enable Developer Mode, and allow camera access when asked.
The bundle identifier is `com.yeyito.signloop`; change it if your team requires a unique ID.

The bootstrap script downloads Google's pinned **MediaPipe 0.10.21** static XCFrameworks,
the **Gesture Recognizer float16 v1** bundle (SHA-256 checked), and the Hand Landmarker
model used by research tools (excluded from the app to avoid duplicate model assets).
Large artifacts and the generated Xcode project are ignored by Git. SDK license
notices are copied from Vendor into the app's resources.
The app links the device/simulator graph archive explicitly, matching Google's CocoaPods spec.

```sh
# Math, buffering and coordinate-mapping tests (no iPhone required)
bash scripts/test-core.sh

# Device build with your team
xcodebuild -project Signloop.xcodeproj -scheme Signloop \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath build DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  -allowProvisioningUpdates build
```

### On-phone demo checklist

1. Allow Camera. In good lighting, put a complete hand in frame.
2. Confirm all 21 joints follow the hand and fingertip dots follow the fingertips.
3. Add a second hand, then remove both; the skeleton/current sign should clear.
4. Try each camera; check overlay alignment, mirroring and left/right labels.
5. Pause/resume and background/foreground the app; no stale signs should persist.
6. Test the one-handed ILY handshape, all other canned gestures, hand removal,
   camera switching and low light. Other words are not supported locally yet.
7. Test with another person. **Do not interpret hand tracking as sign-recognition validation.**

### Implementation

`ios/Signloop/CameraTracker.swift` owns capture and MediaPipe inference on a serial background
queue; late capture frames are dropped instead of building a backlog. MediaPipe's video
mode processes a timestamped sequence and retains temporal tracking. Inference is capped at
24 submissions/sec. Cloud recognition is independently rate-limited.

`Recognition.swift` defines raw/normalized landmarks, a bounded sequence buffer, and
`SignClassifier`. The stub is an integration seam, not a trained sign recognizer.

Coordinates are portrait image-normalized x/y (mirrored for the front camera).
MediaPipe z is relative depth, **not meters**. Export contains raw frames plus wrist-relative,
palm-size-normalized hands. Absolute motion is preserved in the raw stream. Hand array order
is not a persistent identity: a future recognizer must associate hands across frames and
validate handedness under mirroring/occlusion.

The preview and skeleton share aspect-fill scaling; the app is deliberately portrait-only.
No camera images/video are recorded or uploaded. While active and unpaused,
the app automatically sends landmark windows to the backend/Backboard for inference.
The live UI discloses cloud analysis. The app does not save samples or a transcript.
Provider retention policies still apply despite best-effort gateway-record cleanup.

## Next validation milestone

Camera → MediaPipe → **backend** Jev/Backboard → segmentation → **backend** Cerebras → captions.

- The backend client conforms to `SignClassifier`; all provider API secrets stay off the phone.
- Backboard's typed Jev schema is adapted to candidate labels/scores + `unknown`.
- Validate 5–10 signs with human examples and a held-out signer; reject unknown input.
- Validate temporal stability, uncertainty rejection and latency on actual hands.
- The current-sign UI displays Jev's label directly. The guarded Cerebras caption
  endpoint remains available for future phrase assembly, off the live hot path.
- Revisit the small-model choice: the listed 8B route is unavailable; the current
  verified Cerebras route uses GPT-OSS-120B.

Hand landmarks omit facial expression and body context. This is a limited-vocabulary research
prototype, not full ASL translation or an accessibility-critical communication tool.
