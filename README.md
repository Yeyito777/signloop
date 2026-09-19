# Signloop

Hack the North · limited-vocabulary ASL-to-English prototype.

## Experimental cloud recognition

An optional server-only Backboard adapter now connects **Jev → Cerebras** using
one hackathon API key. The iPhone can explicitly submit a two-second gesture,
capture labelled reference examples, and show raw labels alongside guarded captions.
The camera-only demo still works entirely offline.

**Not yet validated ASL recognition:** no reference signs ship with the app;
you must capture real examples, test unknown inputs and evaluate a held-out signer.
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
No API keys, backend, or network access are needed at runtime.

- Live front/rear camera, portrait orientation and mirrored selfie preview.
- Up to two hands, 21 joints per hand, finger connections and optional joint indices.
- Left/right colors, hand/joint counts, tracking FPS and model latency.
- Pause/resume, permission handling, background suspension.
- Two-second temporal landmark buffer, wrist/palm normalization, JSON export via share sheet.
- Replaceable classifier protocol. The default unconfigured classifier returns
  `unknown`. Experimental backend mode is opt-in, manually segmented, and
  requires user-labelled references; it is **not validated ASL translation**.

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
3. Add a second hand; confirm 42 joints. Remove both; the overlay should clear.
4. Try each camera; check overlay alignment, mirroring and left/right labels.
5. Toggle skeleton and indices, pause/resume, background/foreground the app.
6. Share the last two seconds as JSON. Check timestamps, handedness and 21 xyz points.
7. Test with another person. **Do not interpret hand tracking as sign-recognition validation.**

### Implementation

`ios/Signloop/CameraTracker.swift` owns capture and MediaPipe inference on a serial background
queue; late capture frames are dropped instead of building a backlog. MediaPipe's video
mode processes a timestamped sequence and retains temporal tracking. Inference is capped at
24 submissions/sec; the displayed FPS is processed frames, not camera FPS.

`Recognition.swift` defines raw/normalized landmarks, a bounded sequence buffer, and
`SignClassifier`. The stub is an integration seam, not a trained sign recognizer.

Coordinates are portrait image-normalized x/y (mirrored for the front camera).
MediaPipe z is relative depth, **not meters**. Export contains raw frames plus wrist-relative,
palm-size-normalized hands. Absolute motion is preserved in the raw stream. Hand array order
is not a persistent identity: a future recognizer must associate hands across frames and
validate handedness under mirroring/occlusion.

The preview and skeleton share aspect-fill scaling; the app is deliberately portrait-only.
No frames are recorded or uploaded. Explicit export writes landmark JSON to a temporary
file for sharing. Optional backend mode sends coordinates/references only on explicit
actions after consent. Backboard may retain submitted messages. Movement data may be
personal; share it deliberately.

## Next validation milestone

Camera → MediaPipe → **backend** Jev/Backboard → segmentation → **backend** Cerebras → captions.

- The backend client conforms to `SignClassifier`; all provider API secrets stay off the phone.
- Backboard's typed Jev schema is adapted to candidate labels/scores + `unknown`.
- Validate 5–10 signs with human examples and a held-out signer; reject unknown input.
- Add temporal sign boundaries, uncertainty rejection and duplicate suppression.
- Preserve meaning/uncertainty during English rendering; display raw signs beside captions.
- Revisit the small-model choice: the listed 8B route is unavailable; the current
  verified Cerebras route uses GPT-OSS-120B.

Hand landmarks omit facial expression and body context. This is a limited-vocabulary research
prototype, not full ASL translation or an accessibility-critical communication tool.
