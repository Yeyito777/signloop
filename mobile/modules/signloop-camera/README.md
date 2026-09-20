# Native recognition handoff

The Expo SDK 55 module runs the same `SkeletonCameraTracker` → `SkeletonPipeline`
→ `BasicLiveRecognition` → `BasicSignMatcher` path as the standalone scanner.
It uses one camera session. Images and landmark windows stay native and in RAM;
only status, tentative word predictions, and expression labels cross into JavaScript.

## Build and provision

From `mobile/`:

```sh
npm run camera:assets
npx pod-install ios
npm run ios -- --device
npm run camera:references -- /absolute/path/basic-references.json DEVICE_ID
```

The assets command downloads and SHA-256 verifies Google's public hand, face, and
lite pose models. CocoaPods includes them in `SignloopCameraModels.bundle`. Face
tracking shares the existing camera and feeds the scanner's `TaughtExpressionRuntime`.
The standalone app retains its own settings and expression teaching UI.

Load a checked expression profile from `Documents/DemoExpressionProfile.json`
in the goose app, or optionally bundle the gitignored
`ios/Signloop/Resources/DemoExpressionProfile.json` before installing pods and
rebuilding. A profile saved in the in-app Expression lab works too. The newest
local profile takes precedence; an invalid local replacement is
reported instead of silently using a different profile. Pause/resume reloads it.
See [recovery and provisioning commands](../../../docs/goose-expression-integration.md).

Recognition also requires the existing private word reference bank in
**`com.signloop.mobile` → `Documents/basic-references.json`**. The provisioning
command validates the bank with the real Swift matcher and copies it into that
app's container. The standalone scanner uses a different bundle ID; its file
is not shared automatically. Use your own locally generated bank under the research license and
keep it out of Git. No private bank is included in this repository or app bundle.

After provisioning, tap **Retry recognition setup** (or pause and resume).
Missing and invalid banks have distinct visible states, and load failures can
be retried without restarting the app. A missing tracking model requires a
complete new native build.

Swift changes require reinstalling the native app. `recognitionVersion: 5`
lets the JS adapter detect an incompatible native installation and explain that a
rebuild is needed instead of silently showing no results. Expo Go cannot load
this module. Simulator can exercise UI but cannot recognize camera input.

## Contract

`SignloopCamera` accepts `active`, `captureId`, `showSkeleton`, view styles,
`onStatus`, `onPrediction`, and `onExpression`. Types are in `events.ts`.

- Status includes a capture ID, hand count, diagnostic message and state:
  camera startup/access/errors; missing models; reference loading/failure;
  missing hands/shoulders; or ready tracking.
- Predictions identify `basic-temporal-v3`, the capture ID, a label (or null),
  `matched`, the phase (`preview`, `completed`, or `cleared`), and the **input
  frame's** wall-clock observation time. Rolling and completed rankings share an
  attempt ID and include up to three ranked labels with distances. Distances are not confidence
  probabilities; completed results remain explicitly uncertain.
- Predictions also carry `emotion`: neutral, joy, sadness, anger, fear, or disgust.
  It summarizes stable expression observations from that prediction's input
  interval, so a slow matcher does not use a later face. More than half the interval
  must support the same expression; unknown time and ties fall back to neutral.
  Completing a sign freezes its expression with the word for speech and replay.
- `onExpression` carries capture ID, wall-clock observation time, status, and the
  same six-value emotion contract. The taught matcher requires a 300 ms hold;
  nonmatching, ambiguous, missing, or misaligned faces clear to neutral. Native
  transitions emit immediately, with a 200 ms heartbeat. JS rejects old
  generations/out-of-order samples and clears unrefreshed expression after 600 ms.
  Setup failures have explicit statuses and do not block hand/body recognition.
- The presentation vocabulary is HELLO, MY, NAME, TODAY, WE, SHOW, PHONE,
  PLEASE, SORRY, THANKYOU, ILOVEYOU. Spell name separately supports the AURELIO alphabet.
- Fresh rolling guesses display one best match. Gesture completion automatically
  adds the best match to the caption and voice queue; no selection or confirmation
  is required. Delivery must be within one second of observation. Invalid labels,
  stale events, old capture generations and repeated attempt IDs cannot add speech.
  Live previews expire after one second without fresh input.
- The shared SignSegmenter detects movement/rest and static holds. This adapter
  uses 200 ms of elapsed-time motion history and preserves the attempt's leading
  observations even when onset detection is late. The trained SignEngine keeps
  its existing frame-based defaults. Matching a completed gesture uses its
  whole hand/body sequence instead of cropping it to the preview window. A
  bounded queue preserves completions while the worker is busy. Tracking loss
  immediately cancels the gesture rather than treating missing hands as its end.
- The existing acceptance policy was calibrated on rolling windows, so native
  completed events always carry `matched: false`. Automatic speech uses the
  lowest-distance completed ranking, not that flag. These rankings are still
  uncalibrated experimental guesses. Rolling previews never speak; a held pose
  cannot repeat a completed attempt. Fresh movement begins the next attempt.
- Pausing/backgrounding stops capture and resets recognition. A changed
  capture ID resets matching and rejects earlier frames/jobs without rebuilding
  the tracking models. Hand/body loss and camera stalls clear predictions.
- The full portrait preview uses aspect-fit with matching mirrored overlay
  geometry, so the goose's short camera tile does not crop away sign evidence.

## Validation

Run `npm run typecheck`, `npm test`, and `bash ../ios/scripts/test-core.sh`.
Tests cover the actual native vocabulary mapping to automatic captions, the
existing voice path, best-match selection, duplicate suppression,
completed-gesture boundaries, stale/generation rejection, reference load/retry
failures, worker reset callbacks, and fit/mirror geometry. Synthetic
Swift fixtures check the pipeline; they do not establish live ASL accuracy.

On a physical phone with the private bank installed:

1. Open the rebuilt goose app and Start conversation. Confirm hands and both
   shoulders are visible, with joints aligned to the selfie preview.
2. Try the 11 supported signs, keeping hands and shoulders in view. One guess
   should update while signing. Pause briefly; the best completed match should
   appear as a caption without tapping anything.
3. Repeat with voice disabled, then with configured voice enabled. Check caption,
   speech, goose animation, edit/replay, held-sign deduplication, and repeating a
   sign with fresh movement. Consecutive completed signs should speak in order.
4. Remove hands/shoulders, pause/resume, open a sheet, and background/return.
   No old prediction may reappear or trigger speech.
5. Test missing/invalid references and Retry after installing a valid bank.
   Do not interpret tracking readiness or offline tests as accuracy validation.
6. With the checked personal expression profile installed, test all six labels,
   face loss, pause, and expression changes between signing, completion, and speech.
   Follow the [expression device checklist](../../../docs/goose-expression-integration.md#phone-validation).

# Integrated spelling, expression lab and licensed setup

The version-5 bridge preserves the word-review contract above. Expo also exposes the
shared AURELIO alphabet engine, optional face tracking, distance diagnostics and
the existing native Expression lab. See [current integration/setup](../../../docs/expo-detection.md).

**Private word coordinates are intentionally absent from Git.** Each researcher
must read Microsoft's research-only terms and generate their own local bank:
`bash scripts/dev/setup-expo-references --accept-research-license` from the repo
root. Do not upload or send the bank to teammates. The provisioning helper below
is only for your own locally generated bank, not a redistribution workflow.
