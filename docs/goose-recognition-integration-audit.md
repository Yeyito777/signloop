# Goose app recognition investigation

Implementation follow-up: the shared `sunny` checkout now includes main and the
native-to-Expo integration fix, with the existing local edits preserved. The
goose app uses the shared skeleton/word recognizer, maps all 11 presentation
labels, and exposes missing models/references and incompatible native builds.
See [the current setup and phone validation steps](../mobile/modules/signloop-camera/README.md).
Implementation checks passed: mobile TypeScript, all 66 mobile tests, production
iOS JavaScript export, and the complete Swift core suite (including 101 matcher
and 22 segmentation checks). The shared native recognition sources compiled in
the Expo build, but the full app build stopped when the Mac ran out of disk
space. No rebuilt app or reference bank was installed on a phone. These checks
validate integration behavior, not live ASL accuracy.

The investigation below records the original, unchanged main revision; its
line references and descriptions of missing wiring are historical.

Investigated September 20, 2026 against freshly fetched `origin/main`,
`7e91031813eca3a8d7fe6686e37e415cbaf0d875`.

The new standalone recognizer is **not connected to the Expo goose app on this
revision**. A successful Git merge preserved two separate camera/recognition
implementations. It did not make the goose app use the new one. This explains
why testing the new vocabulary in the goose app produces no words, even if hand
tracking works. It does not establish whether the installed phone build has any
additional camera, performance, or provisioning problem.

The shared `sunny` checkout contains extensive pre-existing uncommitted changes.
It was not merged, reset, stashed, or overwritten. Investigation and checks used
an exact archive of main under `.runtime/asl-integration-main/`, with the existing
mobile dependencies linked in. No app implementation or phone installation was
changed.

## Confirmed breaks on main

| Boundary | Evidence | Consequence |
| --- | --- | --- |
| Standalone recognizer → Expo binary | `SignloopCamera.podspec:15–20` includes `CameraTracker` and the older optional `SignEngine`. It excludes `SkeletonCameraTracker`, `SkeletonPipeline`, `BasicLiveRecognition`, `BasicSignMatcher`, and their hand/body model resources. | The new temporal recognizer is not compiled into the goose app. |
| Native camera → recognition | `mobile/modules/signloop-camera/ios/SignloopCameraView.swift:28–36` constructs `CameraTracker`. The standalone `ios/Signloop/ContentView.swift:13–15` constructs `SkeletonCameraTracker` plus `BasicLiveRecognition`. | The two apps run different pipelines. Their similar previews do not imply equivalent recognition. |
| Optional Core ML prediction → JS | The native view dispatches `onPrediction`, but `mobile/src/integrations/nativeCamera.tsx:19–28` subscribes only to `onSign` and `onStatus`. The translation adapter at line 34 is a no-op. | Even a separately supplied older Core ML SignEngine package would not send its predictions into the goose conversation. Subscribing to this event alone would still not connect the new BasicSignMatcher. |
| Label → candidate/caption | `mobile/src/integrations/localSign.ts:9` permits only `I_LOVE_YOU`. The new presentation vocabulary contains `ILOVEYOU` without underscores, along with ten other labels. | Every label in the new 11-word vocabulary is rejected by the existing JS adapter, including the new spelling of I-love-you. |

The merge report explicitly documents this boundary in
`docs/main-detection-merge.md:46–53`. Its verification section also says the Expo
native iPhone app was not rebuilt or installed during that merge.

## Resource provisioning that the eventual fix must handle

`BasicLiveRecognition.swift:26–28` loads `Documents/basic-references.json` in its
own app container. The standalone bundle ID is `com.yeyito.signloop`; the Expo
bundle ID is `com.signloop.mobile`. A reference file provisioned into the
standalone app will not automatically become available to the Expo app.

The current pod bundles `gesture_recognizer.task` and an optional older Core ML
package. The new pipeline instead requires `hand_landmarker.task` and
`pose_landmarker_lite.task` (plus `face_landmarker.task` only if face tracking is
enabled). `SkeletonPipeline.swift:13` currently resolves its models from
`Bundle.main`; a CocoaPods resource bundle needs an explicit lookup path.

No private word-reference bank was found in the inspected local project,
runtime, or existing worktree files. The phone's app container was not available
to inspect, so missing references on that phone are **not a confirmed finding**.

## Additional framing behavior

The goose native view only counts a hand if all 21 projected joints are within
the visible camera crop (`SignloopCameraView.swift:180–187`). Otherwise it clears
the local sign and emits `searching`, even when the sensor detects the hand.
The goose camera takes only part of the screen and uses aspect-fill cropping.
This can suppress the legacy ILY path; whether it happened during the reported
phone test remains unverified. The new recognizer also needs shoulders/body
evidence, so its framing guidance must reflect that when integrated.

## Reproduction and checks

- Ran `npm test` against the archived main: **53/53 passed**.
- Ran `npm run typecheck` against the archived main: **passed**.
- Directly exercised main's `candidateFromSign` with fresh, current-generation
  events for all 11 presentation labels. All returned `clear-candidate`:
  `HELLO`, `MY`, `NAME`, `TODAY`, `WE`, `SHOW`, `PHONE`, `PLEASE`, `SORRY`,
  `THANKYOU`, `ILOVEYOU`.
- The old `I_LOVE_YOU` event returned `candidate`. Feeding it through the
  session reducer and explicitly confirming created the expected caption.
- A fresh `HELLO` event with camera framing already `ready` produced no
  candidate, caption, or speech. Thus the rejection is reproducible without a
  camera, model-confidence issue, or voice-provider request.
- Existing `mobile/tests/live-integration.test.ts` explicitly expects `HELLO` to
  be rejected. Passing these tests validates the old ILY-only contract, not the
  requested ASL-to-goose integration.
- Device discovery found Sunny's iPhone with state `unavailable`. Live frames,
  installed build, native logs, and phone accuracy could not be checked.

## Concrete repair scope

1. Include the new skeleton tracker/matcher sources and required hand/body
   resources in the Expo pod, with resource lookup that supports its bundle.
2. Have the Expo view own that pipeline, connect skeleton frames and resets to
   the recognizer, and provision the private reference bank in the Expo app's
   own Documents directory. Expose missing-resource errors clearly.
3. Define a native result event for this matcher and map the supported labels
   to the existing confirmation-candidate flow. Preserve capture generation,
   freshness, hand/body loss, pause, and background invalidation.
4. Keep uncertainty explicit: `BasicLiveRecognition.sign` currently exposes the
   best-ranked label even when acceptance fails. Do not treat that field as an
   automatically accepted/spoken translation. Retain user confirmation or
   expose the actual accepted/stable decision separately.
5. Add integration coverage for supported labels, missing references,
   uncertain results, lifecycle resets, and the actual native event connection.
6. Rebuild and install the Expo native app, then test the full camera → matcher
   → candidate → confirmation → caption/voice flow on the phone. A Metro reload
   cannot add Swift sources or native model resources to an existing binary.

The investigation is complete; this report is not a claim that the adapter has
been implemented or that the phone behavior has been fixed.
