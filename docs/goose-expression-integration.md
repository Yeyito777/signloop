# Goose expression integration

The Expo app uses the standalone scanner's taught-expression matcher to drive
the goose's pose and optional voice delivery. The six values are **neutral, joy,
sadness, anger, fear, and disgust**. They name demonstrated facial patterns;
they do not establish a person's feelings or linguistic ASL meaning.

## Data flow

1. The existing native camera runs hand, body, and face models on the same frames.
   `TaughtExpressionRuntime` uses the demonstrator's checked, frozen profile.
2. A match must hold for 300 ms. Face loss, unknown/ambiguous patterns, head-angle
   mismatch, or tracking interruption return to neutral. Native status changes
   emit immediately with a 200 ms heartbeat; JS expires events after 600 ms and
   rejects old capture generations and out-of-order observations.
3. A bounded native history associates expression with the sign matcher's input
   interval. A non-neutral pattern must occupy more than half that interval.
   Mixed patterns, missing evidence, and ties yield neutral. This retains the
   expression if the signer briefly relaxes before the recognition job completes.
4. Each tentative choice includes that expression. Tapping a choice freezes its
   word, expression, and expiry. Confirmation creates a phrase carrying the same
   expression. Later camera events cannot rewrite it.
5. Speech receives `{ text, emotion }`. Each queued phrase, replay, and text
   correction retains its own expression. The backend selects the matching voice
   settings and delivery tags; neutral adds no tags. Nothing is spoken until the
   user confirms, and voice still requires consent.
6. While listening, the goose follows the fresh live expression, even with voice
   muted. During speech preparation and playback, it uses the phrase's expression.
   Afterward it returns to live tracking or neutral. Pause/sheets reset it.

Camera frames and landmarks stay native/on-device. Only compact labels and
status cross to JS. Voice uploads send confirmed text and its label to the
authenticated backend; the provider receives text with delivery directions.

## Find the real profile

The standalone scanner's source saves the checked profile inside its app:

```text
Bundle ID: com.yeyito.signloop
Library/Application Support/Signloop/demo-expressions.json
```

An unfinished Expression lab setup is a different file and cannot be used as a
checked demo profile. There is no checked profile committed to this repository.
The integration work found no exported copy locally or in the inspected task
history. The registered Sunny's iPhone was unavailable, so its saved file has
not yet been recovered or validated. No synthetic profile has been installed.

When the scanner's phone is connected, unlocked, and trusted, run from `mobile/`:

```sh
npm run camera:recover-expressions -- DEVICE_ID
```

This reads the scanner's saved file without changing it, validates it with the
actual Swift schema/checks, and stages the gitignored bundle resource at
`ios/Signloop/Resources/DemoExpressionProfile.json` in the repository root. If
the file is absent, open Expression lab in the scanner, finish its six checks,
and save/export the checked profile.

## Build and provision

The bridge is now `recognitionVersion: 5`; an older installed binary needs a
native rebuild. From `mobile/`, after recovering or staging the profile:

```sh
npm run camera:assets
npx pod-install ios
npm run ios -- --device
```

Alternatively, provision a checked export into a rebuilt goose app:

```sh
npm run camera:expressions -- /absolute/path/DemoExpressionProfile.json DEVICE_ID
```

This validates and copies it into `com.signloop.mobile/Documents/DemoExpressionProfile.json`.
Pause/resume to reload. A valid local file overrides the optional bundle profile.
An invalid replacement is reported instead of silently using another profile.
Missing or invalid profiles keep delivery neutral and show setup guidance;
hand/body recognition and captions remain available. The private sign reference
bank still needs its separate `camera:references` provisioning step.

## Automated validation

```sh
cd mobile
npm run typecheck
npm test
cd ..
node --experimental-strip-types --test goose/tests/*.test.ts
python3 -m unittest backend.test_voice
bash ios/scripts/test-core.sh
```

Tests cover all six labels through native prediction mapping, confirmation,
goose state, and mocked speech transport; expression freezing, queue/replay/
correction behavior, face loss, lifecycle/freshness guards, profile validation,
historical window selection, and backend delivery settings. Native Swift source
was also typechecked against the iPhone SDK and installed Expo/MediaPipe modules.
These are synthetic and mocked checks, not evidence of live expression accuracy
or audible delivery quality.

## Phone validation

1. Use the rebuilt app with the demonstrator's actual checked profile and sign
   reference bank. Verify each of the six patterns changes the listening goose
   appropriately, with neutral at rest and no flicker during short transitions.
2. Sign with each expression, select a choice, relax/change your face, then
   confirm. The phrase's goose pose and voice should retain the signing expression.
3. Queue two phrases with different expressions. Verify their individual delivery,
   replay, and a text correction retain the expected expression.
4. Test face loss, turning away, pause/resume, opening sheets, background/return,
   and missing/invalid profile setup. No old face or sign should reappear.
5. Test with voice disabled and without network access: local tracking and
   captions must continue. With configured voice, listen to the actual delivery
   and tune tags/presets if necessary; provider output is not deterministic acting.

The phone rebuild/install, real profile recovery, and these physical checks
remain separate from the implemented integration.
