# Signloop

Hack the North · limited-vocabulary ASL-to-English prototype.

## One-screen live sign estimates

Open the app, put your hands in view, and see the **current possible sign** update
automatically over the full-screen camera. No settings workflow, reference
capture, saving, or Analyze button. Pause/flip stay on the camera; the top-right
settings button controls hand joints, joint numbers and tracking stats.

MediaPipe runs locally; a server-only Backboard adapter asks Jev to evaluate a
recent landmark window using built-in sign descriptions. It targets roughly one
request/second with no backlog, stabilization and stale-result rejection.
**This is experimental zero-shot inference, not validated ASL recognition.**
See [backend setup, verified models and limitations](docs/backend.md).

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

Native iPhone app with **Google MediaPipe Hand Landmarker**, not simulated joints.
Hand tracking works locally. Live sign estimates require the provisioned Mac
backend and network; provider API keys are never embedded in the phone.

- Live front/rear camera, portrait orientation and mirrored selfie preview.
- Up to two hands, 21 joints per hand and an optional colored skeleton.
- Camera-first Material-inspired design with a single current-sign overlay.
- Persistent overlay preferences in the top-right settings sheet.
- Pause/resume, permission handling, background suspension.
- Two-second memory buffer; latest 1.2 seconds used for automatic inference.
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

The bootstrap script downloads Google's pinned **MediaPipe 0.10.21** static XCFrameworks
and the **Hand Landmarker float16 v1** model. These large artifacts and the generated Xcode
project are ignored by Git. Google Apache license files ship in the downloaded Vendor folders.
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
6. Test live supported signs and unsupported gestures; no manual capture is needed.
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
