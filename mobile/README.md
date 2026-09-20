# Honk & Tell mobile

Expo SDK 55 / React Native Playroom app with the **shared 3D goose, native Swift
camera, offline 11-sign temporal matching, explicit confirmation, captions, and
optional server-proxied ElevenLabs voice, and taught facial-expression delivery**. A separate sample conversation
preserves the UI review flow; real hand detection never generates sample captions.
The goose is expressive animation, not an ASL signing avatar.

## Run on iOS

Requires Node 22.13+ (24 recommended), CocoaPods, and Xcode 26.2+. Expo SDK 55 / React Native 0.83 supports the installed Xcode 26.3; SDK 56/57 require Xcode 26.4+.

From this directory:

```sh
npm ci
npm run ios
```

`preios` downloads and checksum-verifies Google's public Hand, Face, and
lite Pose Landmarker models. CocoaPods installs MediaPipe 0.10.21. Expo generates `mobile/ios/`,
builds a development app, opens Simulator, and starts Metro. Native folders are
generated and ignored by Git. The camera requires iOS 17+.

The local Expo module compiles the shared Swift sources under root `ios/Signloop/`; it does not copy them. The standalone native app remains separately buildable. If running `expo prebuild` or `pod install` manually, run `npm run camera:assets` first. Do not prebuild the repository root.

After the first build, `npm start` and then `i` reopens the installed app. To open in Xcode after generation: `open ios/*.xcworkspace`. Metro must run for a Debug build. No Expo account or signing team is needed for Simulator.

For an existing checkout upgrading to **Honk & Tell**, run `npx expo prebuild --platform ios --no-install` before rebuilding to sync the display name and URL schemes into the generated native project. Then run `npm run ios -- --device` to update the phone. The bundle ID stays `com.signloop.mobile`, and existing `signloop://` links remain supported alongside `honk-and-tell://`.

`postinstall` and the local Expo config plugin apply narrow path-quoting fixes to SDK 55 native scripts so a checkout named `htn 2026` builds correctly. Review/remove these patches when upgrading React Native or Expo. Generated native files are not the source of these fixes.

## Review

Start conversation requests camera permission on iPhone and shows a mirrored preview, native joint overlay, and hand visibility feedback. Permission denial offers Settings. Simulator and platforms without the module show an unavailable state with an explicit UI demo option.

Home offers Start conversation and Voice settings. Simulator camera guidance
links to an explicitly labelled sample preview. The rebuilt native app runs the
standalone recognizer's 11-word presentation vocabulary, with full-frame hand
and shoulder tracking. Up to three uncertain choices update as you sign, without
waiting for gesture completion. Tap the intended choice to freeze it, then
**Confirm selected sign**, or choose **None of these**. A selection keeps its
original ten-second expiry and clears on tracking loss. **Review another sign**
starts a fresh attempt after confirmation or rejection. This is a limited research preview,
not validated general ASL translation. Rebuild the native app for recognition
contract version 5; a Metro reload alone cannot update native expression tracking.

Install the working recognizer's private reference bank in the goose app's own
storage after rebuilding; the standalone scanner's file does not transfer:

```sh
npm run camera:references -- /absolute/path/basic-references.json DEVICE_ID
```

The helper validates the actual Swift matcher and copies into
`com.signloop.mobile/Documents/basic-references.json`. Then tap Retry recognition
setup or pause/resume. An old installed binary, missing tracking models, and
missing/invalid references have explicit UI states. See the
[native recognition handoff](modules/signloop-camera/README.md) for the contract
and phone checklist.

Expression delivery uses the standalone scanner's checked personal profile. With
the scanner's phone connected, recover its saved profile before rebuilding:

```sh
npm run camera:recover-expressions -- DEVICE_ID
npx pod-install ios
npm run ios -- --device
```

Alternatively, install an existing checked export into the rebuilt app with
`npm run camera:expressions -- /absolute/path/DemoExpressionProfile.json DEVICE_ID`,
then pause/resume. Profiles stay out of Git. Without one, captions still work and
the app explains that expression setup is needed; delivery stays neutral.
See [expression integration and recovery](../docs/goose-expression-integration.md).

For UI testing, `/conversation?demo=1` runs a finite sample: framing → ready → draft
→ thinking → accepted phrase → silent voice preview. “Demo · try states” opens
additional scenarios. Use the caption pencil to correct and the top-right menu
to read the transcript, mute voice, or end. Back also confirms End. Transcript
data clears on ending.

Fonts are bundled locally. The UI imports canonical `../design-system/` tokens/icons
and respects system text size and Reduce Motion. The live app imports Sanvi's
reusable `../goose/src/components/MrGoose` renderer. Metro resolves shared-source
dependencies from `mobile/node_modules`, never the standalone Expo 57 runtime.
See [character handoff](src/avatar/README.md) for native rendering adaptations.
TypeScript-only path mappings are disabled in Metro (`experiments.tsconfigPaths:
false`) so declaration files cannot become runtime modules.

The selected Go big direction uses “You were saying?” on Home, oversized artwork, one ink Start button, open captions, and dark sheets. Home and Conversation share one avatar container: the large character moves into a centered, reserved stage while the camera and caption area appear. Its blue backdrop recedes and a decorative curved line changes shape during the transition. The character renderer stays mounted; only its outer container moves. Direct entry and Reduce Motion skip this movement. Navigation also uses a short native crossfade. Reanimated drives press/release springs, stage travel, and pause/status fades. Gorhom sheets support dragging, a fading backdrop, content resizing, and keyboard-aware correction. Their content remains mounted until dismissal finishes; capture resumes and correction playback begins only afterward. Ending a session keeps capture stopped through the return to Home. OS Reduce Motion disables animation. Expo Haptics supplements completed taps where supported; iOS suppresses haptics while its camera is active, so all meaningful feedback is visual.

Motion timings and springs come from `../design-system/tokens.json`; `src/ui/motion.tsx` owns the shared runtime policy. Use `Touch`, `Button`, `IconButton`, and `Sheet` for new controls. Keep the native camera and 3D avatar mounted when visual status changes. Adding these native animation/gesture/haptic packages requires a new development build once; later JS-only motion tuning uses Fast Refresh.

Camera corner guides settle after 300 ms of stable readiness; transient framing changes wait 450 ms before changing the guidance. This filters presentation only: recognition still reacts immediately to raw scanner events, and permission/device failures appear immediately. Accepted captions remain visible while another phrase is processed or framing is lost. The conversation reserves roughly 45% camera, 30% goose, and 25% captions. Larger system text gets more caption space without shrinking the goose. Long captions and recovery actions scroll inside that region; edit/replay remain above them. Correction briefly shows “Correction saved.”

Manual demo scenarios stay selected until restarted. “Run sample conversation,” retry, or Resume starts a fresh finite example; opening sheets no longer silently starts another sample over a correction.

Expo's floating Tools button can overlap app controls in a development build. Drag it aside, or turn off “Tools button” in the Expo developer menu when reviewing the UI.

## Install on your iPhone

For daily development, connect and trust the iPhone, enable Developer Mode, and select your Apple signing team in Xcode. From `mobile/`, run `npm run ios -- --device` and select the phone. This installs **Honk & Tell's own development build**. Run `npm start` on the Mac and connect from the phone on the same network. A free Personal Team can be used for local testing; paid membership is needed for distribution through TestFlight.

UI/TypeScript edits refresh through Metro. Changes to Swift, native dependencies, or native configuration require rebuilding the installed app. Expo Go cannot load the custom Swift scanner module, so the development build is the recommended workflow from the start. [Expo setup](https://docs.expo.dev/develop/development-builds/introduction/).

TestFlight is supported: configure the team's Apple Developer/App Store Connect and Expo EAS project, produce a signed production build, submit it, and invite testers. A production build bundles the UI and does not need Metro/the Mac. External testing can require Apple's beta review. This repository has not been connected to EAS or TestFlight yet. [Expo submission guide](https://docs.expo.dev/submit/ios/), [Apple TestFlight guide](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview).

```sh
npm run typecheck
npm test
```

## Optional voice

1. Configure the [backend voice proxy](../docs/voice-backend.md). For a trusted
   LAN, run `python3 -m backend.server --voice-only --host 0.0.0.0` from the repo root.
2. Open Voice settings on Home. Enter `http://<your-mac>.local:8787` (or an HTTPS
   deployed origin) and **SIGNLOOP_BACKEND_TOKEN**, never an ElevenLabs key.
3. Enable text-upload consent, save, and tap Test voice. Provider keys and voice
   selection are configured on the backend. Settings are held in app memory only.
4. Start a conversation. Select and confirm a recognized sign. The caption appears
   immediately; optional speech follows. Corrections require explicit Save & speak.

The live goose follows stable taught expressions while listening. Each selected
sign freezes its own expression for confirmation, queued speech, replay, and
correction. Voice uploads include the confirmed text and that expression label.

Backgrounding revokes upload consent and cancels local playback. Pause, mute,
ending, and replacement speech also cancel local playback and clean temporary
audio files. Cancellation cannot retract already submitted provider text or
guarantee cancellation of an already-started billed request. Voice is off by
default; captions continue working without a backend.

The production mobile path uses bounded MP3 responses and timing-driven character
gestures. Newer streaming experiments remain in the standalone `goose/` preview,
not the secure consumer adapter.

See [integration handoff](../docs/frontend-flow-and-handoff.md),
[combined status](../docs/branch-integration.md), and
[native camera module](modules/signloop-camera/README.md). Actual capture,
permissions, GL rendering, audio playback, and skeleton alignment require a
physical iPhone build. Android capture and general ASL translation are not implemented.
