# Signloop

Hack the North · limited-vocabulary ASL-to-English prototype.

## Developer MVP: real on-device hand tracking

Native iPhone app with **Google MediaPipe Hand Landmarker**, not simulated joints.
No API keys, backend, or network access are needed at runtime.

- Live front/rear camera, portrait orientation and mirrored selfie preview.
- Up to two hands, 21 joints per hand, finger connections and optional joint indices.
- Left/right colors, hand/joint counts, tracking FPS and model latency.
- Pause/resume, permission handling, background suspension.
- Two-second temporal landmark buffer, wrist/palm normalization, JSON export via share sheet.
- Honest transcript placeholder and replaceable classifier protocol. The unconfigured classifier
  always returns `unknown`; this build **does not recognize ASL signs or translate**.

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
No frames are recorded or uploaded. Only explicit export writes landmark JSON to a temporary
file for sharing. Export may contain personal movement data; share it deliberately.

## Next milestone

Camera → MediaPipe → **backend** Jev/Backboard → segmentation → **backend** Cerebras → captions.

- Add a backend client conforming to `SignClassifier`; keep all API secrets off the phone.
- Confirm Backboard's native schema and adapt it to candidate labels/scores + `unknown`.
- Validate 5–10 signs with human examples and a held-out signer; reject unknown input.
- Add temporal sign boundaries, uncertainty rejection and duplicate suppression.
- Preserve meaning/uncertainty during English rendering; display raw signs beside captions.
- Confirm Cerebras model/access before integration.

Hand landmarks omit facial expression and body context. This is a limited-vocabulary research
prototype, not full ASL translation or an accessibility-critical communication tool.
