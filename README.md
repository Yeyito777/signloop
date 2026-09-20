# Honk & Tell

Hack the North · limited-vocabulary ASL-to-English prototype.

The app is now **Honk & Tell**. The standalone Xcode project and scheme are
`HonkAndTell`. Existing bundle IDs, saved-data keys, native module names, and
`ios/Signloop/` source paths remain stable so installed apps and integrations keep
working. Rebuild and install the app to update its home-screen name.

## Consumer app design system

The [Playroom design system](design-system/README.md) contains the agreed visual foundation,
portable tokens, React Native text styles, CSS variables, and reusable UI icons.
Screen layouts are still drafts. The imported [3D goose prototype](goose/README.md)
includes animation and experimental voice; the design system keeps character
rendering and animation assets replaceable.

## Unified consumer mobile app

The Expo app lives in [`mobile/`](mobile/README.md): Home, Conversation, and local
transcript/correction sheets in the Playroom style. The native Expo camera module
uses the gesture tracker in `ios/Signloop/CameraTracker.swift`. The app renders
the shared 3D goose and offers a complete
limited flow: **offline ILY handshape estimate → explicit confirmation → caption
→ optional backend-generated goose voice**. Voice uploads require foreground-session
consent in Settings. Provider keys stay on the backend. This is not general ASL
translation. An explicit sample-conversation mode still uses labeled sample data
and silent playback.
See [voice setup](docs/voice-backend.md) and [integration checks](docs/branch-integration.md).
See the [frontend integration handoff](docs/frontend-flow-and-handoff.md).

```sh
cd mobile
npm ci
npm run ios
```

This generates `mobile/ios/` separately from the native scanner prototype below.

## Goose and voice prototype

Sanvi's character, emotion animation, lip sync, and ElevenLabs voice experiment
are preserved in [`goose/`](goose/README.md), with their own lockfile and tests.
Run `npm ci`, `npm run typecheck`, and `npm test` from that directory.

The **standalone Expo 57 preview** remains available for character development.
The Expo 55 consumer app reuses its rendering/animation sources but supplies its
own SDK-compatible dependencies and authenticated backend voice adapter. Its
experimental direct-provider/streaming client is not bundled in the consumer app.
Do not copy its dependency manifest over `mobile/package.json`: SDK 55 is
intentional for the camera app's Xcode compatibility. See
[combined branch status](docs/branch-integration.md) for integration boundaries.
No credentials were imported. Client-side `EXPO_PUBLIC_*` keys in the standalone
prototype are not secret; use the consumer app's backend path for shared builds.

## Standalone native scanner: offline skeleton

The standalone native build uses `SkeletonCameraTracker` for synchronized
MediaPipe hand, upper-body and face tracking, plus an optional taught expression
profile for the demo. No sign guesses,
backend, API key, transcription, recording or uploads.

- Up to two hands, 21 points each.
- Upper-body pose through the hips (25 original MediaPipe landmark IDs).
- 478 face/iris points and 52 facial movement blendshape coefficients.
- Settings toggle hand/body/face overlays, point numbers and performance stats.
- Tap a point or the scope button to inspect live coordinates and facial signals.
- Pause and camera switch clear observations; the two-second probe buffer is RAM-only.

Facial signals are **not sentiment/emotion labels or recognized ASL grammar**.
Coordinates share the camera image plane, not a calibrated 3D coordinate system.
See [architecture, probe schema and testing](docs/multimodal-skeleton.md).

Tap the smiling-face button for [Expression lab](docs/expression-tester.md):
teach your relaxed face and five expressions once, check them against fresh
repetitions, then save/export a fixed personal demo profile. Recognition continues
on the camera screen after the lab closes. The **HonkAndTellDemo** scheme bundles
the checked profile and hides teaching from the demo experience.
The experimental presets do not infer emotion or ASL meaning.

This replaces the standalone camera's earlier ILY/five-sign research display;
old recognition experiments remain below for reference and are not called by the new camera UI.
No private sign-model assets are needed. Installing build 12 replaces the previous
app UI; installation is a separate explicit step.

## Previous recognition research (not active in the tracking UI)

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

A [face-context calibration experiment](docs/face-context-research.md) found
only a small, cadence-sensitive gain. Face tracking remains **disabled** rather
than adding unproven camera overhead.

[Microsoft pretrained video/body-model benchmarks](docs/citizen-baselines.md)
are now complete. On a separate official-split research cohort, a newer-hand +
body hybrid accepted 47/72 complete signs, but displayed only 14/72 with causal
windows. Neither model replaces the phone classifier; these are not sentence
recognition or live-phone accuracy results.

[Capture-time freshness checks](docs/capture-freshness.md) reject delayed and
pre-switch camera frames instead of treating processing time as capture time.
Camera frame age is available in settings; actual phone latency still needs
measurement.

Use the [live phone checklist](docs/live-phone-checklist.md) for offline,
camera/lifecycle, ASL-fluent and held-out-signer validation. No recordings are
required; these uncompleted checks cannot be replaced by simulator results.

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
open HonkAndTell.xcodeproj
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
xcodebuild -project HonkAndTell.xcodeproj -scheme HonkAndTell \
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
