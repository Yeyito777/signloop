# Main / detection integration — build 19

Integration base: `main` at `09273eb`; detection source: `yeyito` at
`8e9bac5`. This is a true merge retaining both histories, not replacement of
main with the standalone prototype.

## Preserved from main

- Honk & Tell branding, Expo app, shared goose, design system and accessibility
  tests; Expo's confirmation/caption/session flow and server-proxied voice.
- The separate `CameraTracker` / SignEngine / Expo native bridge and its
  resource packaging. `mobile/`, `goose/`, `recognition/`, the podspec and existing
  backend service/voice files are unchanged by the integration.
- Camera preview rotation-coordinator fixes and video-output alignment.
- Expression measurements, personal teaching/calibration/import/export, frozen
  profile inference, Demo profile validation and both HonkAndTell Xcode schemes.

## Preserved from detection

- Synchronized hand/body/optional-face skeleton, lifecycle and stale-data resets.
- Temporal matching, hand-local geometry, independent match distances, exact
  pruning, guarded compact WE reference augmentation and private-bank loading.
- The 11-word presentation scope (including ILOVEYOU), score inspector,
  seven-letter AURELIO spelling, explicit Add and transient spelling draft.
- Corpus/export/audit tooling and all associated tests.

The core matcher, spelling engine and skeleton pipeline are byte-identical to
`yeyito`. Original training-bank assets remain private and separately provisioned;
they are neither committed nor embedded by this merge.

## Conflict decisions and compatibility

README describes both apps instead of dropping either one. The SwiftUI screen
combines spelling/matching and expression lab. The core test runner executes
both branches' tests. Xcode retains main's names, Demo configuration, profile
validation and resource rules, with a new build number of 19.

Face tracking remains optional for word-only use. Opening Expression lab enables
it, and an existing saved/bundled expression profile enables it at launch, so the
latency optimization does not silently disable main's expression functionality.
Users can disable face tracking in Settings afterwards; expressions then lack
face evidence and must not be presented as detected. Camera observations do not
retrain profiles. Privacy copy distinguishes transient landmarks from explicitly
saved numeric expression profiles.

## Deliberate boundary

The new temporal/spelling engine is active in the **standalone SwiftUI app**.
Expo still uses main's separate CameraTracker/SignEngine bridge and confirmation
flow. This merge does not silently replace that bridge, convert uncertain best
guesses into accepted captions, upload landmarks, or route private assets into
Expo. Using the new matcher inside Expo would be a separate adapter/UI change,
not something implied by a conflict-free Git merge.

The Demo scheme still requires the user's explicitly exported numeric expression
profile, as on main. Neither installation nor live phone accuracy is established
by these merge checks.

## Verification, September 20, 2026

- Mobile: clean `npm ci`, TypeScript check, all 53 tests (including design-system
  freshness/contrast), and production Expo iOS JS/assets export passed.
- Shared goose: all 38 tests passed.
- Backend discovery: 111 tests, 109 passed and two optional checks skipped.
  Includes the unchanged server-side voice proxy tests, without provider calls.
- Main's recognition package: 48 tests, 47 passed and the optional Core ML
  conversion check skipped.
- Combined Swift core runner passed: capture/lifecycle/skeleton tests, expression
  and taught-profile checks, 90 temporal-matcher checks, 161 SignEngine checks,
  and 18 alphabet/spelling checks. Optional private Core ML artifact parity was
  not run; no research model was bundled to manufacture a pass.
- Standalone unsigned Release iPhone build 19 succeeded.
- Combined simulator UI suite: 17 tests, 16 passed and one Demo-only check
  skipped. Includes the new face-enable/spelling coexistence regression,
  expression teaching, restricted manual alphabet, score panel, privacy and
  accessibility checks.
- File comparison verified main's Expo/goose/recognition trees, native bridge,
  camera orientation implementation and existing backend service/voice were
  unchanged. Detection engines were compared byte-for-byte with `yeyito`.
- Source and app credential scan passed; no private word-reference bank bundled.

Expo's native iPhone application was not rebuilt or installed in this task;
its unchanged native bridge and JS bundle were checked separately. The Demo
scheme was retained but not run with a personal profile. Live camera performance,
sign accuracy, actual voice-provider access and real-phone behavior remain
outside these offline integration tests.
