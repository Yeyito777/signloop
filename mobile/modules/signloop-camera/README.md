# Native recognition handoff

The Expo SDK 55 module runs the same `SkeletonCameraTracker` → `SkeletonPipeline`
→ `BasicLiveRecognition` → `BasicSignMatcher` path as the standalone scanner.
It uses one camera session. Images and landmark windows stay native and in RAM;
only status and tentative word predictions cross into JavaScript.

## Build and provision

From `mobile/`:

```sh
npm run camera:assets
npx pod-install ios
npm run ios -- --device
npm run camera:references -- /absolute/path/basic-references.json DEVICE_ID
```

The assets command downloads and SHA-256 verifies Google's public hand and lite
pose models. CocoaPods includes them in `SignloopCameraModels.bundle`. Face
tracking is disabled for this word-only Expo path. The standalone app retains
its own settings and optional face/expression functionality.

Recognition also requires the existing private word reference bank in
**`com.signloop.mobile` → `Documents/basic-references.json`**. The provisioning
command validates the bank with the real Swift matcher and copies it into that
app's container. The standalone scanner uses a different bundle ID; its file
is not shared automatically. Use the packed bank from the working scanner and
keep it out of Git. No private bank is included in this repository or app bundle.

After provisioning, tap **Retry recognition setup** (or pause and resume).
Missing and invalid banks have distinct visible states, and load failures can
be retried without restarting the app. A missing tracking model requires a
complete new native build.

Swift changes require reinstalling the native app. `recognitionVersion: 3`
lets the JS adapter detect an incompatible native installation and explain that a
rebuild is needed instead of silently showing no results. Expo Go cannot load
this module. Simulator can exercise UI but cannot recognize camera input.

## Contract

`SignloopCamera` accepts `active`, `captureId`, `showSkeleton`, view styles,
`onStatus`, and `onPrediction`. Types are in `events.ts`.

- Status includes a capture ID, hand count, diagnostic message and state:
  camera startup/access/errors; missing models; reference loading/failure;
  missing hands/shoulders; or ready tracking.
- Predictions identify `basic-temporal-v2`, the capture ID, a label (or null),
  `matched`, the phase (`preview`, `completed`, or `cleared`), and the **input
  frame's** wall-clock observation time. Completed gestures include an attempt
  ID and up to three ranked labels with distances. Distances are not confidence
  probabilities; completed results remain explicitly uncertain.
- The presentation vocabulary is HELLO, MY, NAME, TODAY, WE, SHOW, PHONE,
  PLEASE, SORRY, THANKYOU, ILOVEYOU. There is no alphabet/spelling UI in Expo.
- Rolling guesses are previews only. A completed gesture opens a review with
  up to three choices and **None of these**. Selecting a choice and confirming
  it are separate actions; only confirmation produces a caption or speech.
  Delivery must be within one second of observation; an accepted review lasts
  up to ten seconds. Invalid labels, stale events, old capture generations and
  old attempt IDs cannot confirm a caption.
- The shared SignSegmenter detects movement/rest and static holds, retains
  pre-roll, and rearms on fresh movement. Matching a completed gesture uses its
  whole hand/body sequence instead of cropping it to the preview window. A
  bounded queue preserves completions while the worker is busy. Tracking loss
  immediately cancels the gesture rather than treating missing hands as its end.
- The existing acceptance policy was calibrated on rolling windows. Whole
  segments therefore remain uncertain until separately evaluated and calibrated.
  Rolling previews cannot change the selected option or extend the ten-second
  review deadline. A newer completed gesture replaces the previous review.
- Pausing/backgrounding stops capture and resets recognition. A changed
  capture ID resets matching and rejects earlier frames/jobs without rebuilding
  the tracking models. Hand/body loss and camera stalls clear predictions.
- The full portrait preview uses aspect-fit with matching mirrored overlay
  geometry, so the goose's short camera tile does not crop away sign evidence.

## Validation

Run `npm run typecheck`, `npm test`, and `bash ../ios/scripts/test-core.sh`.
Tests cover the actual native vocabulary mapping to confirmed captions, the
existing voice path, explicit uncertainty, alternative selection/rejection,
completed-gesture boundaries, stale/generation rejection, reference load/retry
failures, worker reset callbacks, and fit/mirror geometry. Synthetic
Swift fixtures check the pipeline; they do not establish live ASL accuracy.

On a physical phone with the private bank installed:

1. Open the rebuilt goose app and Start conversation. Confirm hands and both
   shoulders are visible, with joints aligned to the selfie preview.
2. Try the 11 supported signs, relaxing between gestures with hands still in
   view. A completed gesture should show uncertain choices; rolling previews
   cannot be confirmed. Nothing should be added or spoken automatically.
3. Select and confirm a choice with voice disabled, then with configured voice
   enabled. Check alternatives, None of these, expiry, caption, speech, goose
   animation, held-sign deduplication, and repeating a sign after relaxing.
4. Remove hands/shoulders, pause/resume, open a sheet, and background/return.
   No old prediction may reappear or remain confirmable.
5. Test missing/invalid references and Retry after installing a valid bank.
   Do not interpret tracking readiness or offline tests as accuracy validation.
