# Signloop mobile

Expo / React Native Playroom screens: Home and Conversation, with transcript and correction sheets. Start conversation opens the **native Swift camera and MediaPipe hand tracker** on iPhone. Sanvi’s 3D goose is connected through the shared avatar adapter. Translation and ElevenLabs are not connected yet. A separate sample conversation preserves the UI review flow; real hand detection never generates sample captions.

## Run on iOS

Requires Node 22.13+ (24 recommended), CocoaPods, and Xcode 26.2+. Expo SDK 55 / React Native 0.83 supports the installed Xcode 26.3; SDK 56/57 require Xcode 26.4+.

From this directory:

```sh
npm ci
npm run ios
```

`preios` downloads Google's pinned Hand Landmarker float16 v1 model if missing. CocoaPods installs MediaPipe 0.10.21. Expo generates `mobile/ios/`, builds a development app, opens Simulator, and starts Metro. Native folders are generated and ignored by Git. The camera requires iOS 17+.

The local Expo module compiles the shared Swift sources under root `ios/Signloop/`; it does not copy them. The standalone native app remains separately buildable. If running `expo prebuild` or `pod install` manually, run `npm run camera:assets` first. Do not prebuild the repository root.

After the first build, `npm start` and then `i` reopens the installed app. To open in Xcode after generation: `open ios/Signloop.xcworkspace`. Metro must run for a Debug build. No Expo account or signing team is needed for Simulator.

`postinstall` and the local Expo config plugin apply narrow path-quoting fixes to SDK 55 native scripts so a checkout named `htn 2026` builds correctly. Review/remove these patches when upgrading React Native or Expo. Generated native files are not the source of these fixes.

## Review

Start conversation requests camera permission on iPhone and shows a mirrored preview, native joint overlay, and hand visibility feedback. Permission denial offers Settings. Simulator and platforms without the module show an unavailable state with an explicit UI demo option.

Home has one Start conversation action. For UI testing, `/conversation?demo=1` runs a finite sample: framing → ready → draft → thinking → accepted phrase → silent voice preview. “Demo · try states” opens additional scenarios. Use the caption pencil to correct and the top-right menu to read the transcript, mute voice, or end. Back also confirms End. Transcript data clears on ending.

Fonts are bundled locally. The UI imports canonical `../design-system/` tokens/icons and respects system text size and Reduce Motion. The procedural 3D goose comes from `sanvi-signloop` at `575074e`; see [character handoff](src/avatar/README.md).

The selected Go big direction uses “You were saying?” on Home, oversized artwork, one ink Start button, open captions, and dark sheets. Home and Conversation share one avatar container: the large character moves into a centered, reserved stage while the camera and caption area appear. Its blue backdrop recedes and a decorative curved line changes shape during the transition. The character renderer stays mounted; only its outer container moves. Direct entry and Reduce Motion skip this movement. Navigation also uses a short native crossfade. Reanimated drives press/release springs, stage travel, and pause/status fades. Gorhom sheets support dragging, a fading backdrop, content resizing, and keyboard-aware correction. Their content remains mounted until dismissal finishes; capture resumes and correction playback begins only afterward. Ending a session keeps capture stopped through the return to Home. OS Reduce Motion disables animation. Expo Haptics supplements completed taps where supported; iOS suppresses haptics while its camera is active, so all meaningful feedback is visual.

Motion timings and springs come from `../design-system/tokens.json`; `src/ui/motion.tsx` owns the shared runtime policy. Use `Touch`, `Button`, `IconButton`, and `Sheet` for new controls. Keep the native camera and 3D avatar mounted when visual status changes. Adding these native animation/gesture/haptic packages requires a new development build once; later JS-only motion tuning uses Fast Refresh.

Camera corner guides settle after 300 ms of stable readiness; transient framing changes wait 450 ms before changing the guidance. This filters presentation only: recognition still reacts immediately to raw scanner events, and permission/device failures appear immediately. Accepted captions remain visible while another phrase is processed or framing is lost. The conversation reserves roughly 45% camera, 30% goose, and 25% captions. Larger system text gets more caption space without shrinking the goose. Long captions and recovery actions scroll inside that region; edit/replay remain above them. Correction briefly shows “Correction saved.”

Manual demo scenarios stay selected until restarted. “Run sample conversation,” retry, or Resume starts a fresh finite example; opening sheets no longer silently starts another sample over a correction.

Expo's floating Tools button can overlap app controls in a development build. Drag it aside, or turn off “Tools button” in the Expo developer menu when reviewing the UI.

## Install on your iPhone

For daily development, connect and trust the iPhone, enable Developer Mode, and select your Apple signing team in Xcode. From `mobile/`, run `npm run ios -- --device` and select the phone. This installs **Signloop's own development build**. Run `npm start` on the Mac and connect from the phone on the same network. A free Personal Team can be used for local testing; paid membership is needed for distribution through TestFlight.

UI/TypeScript edits refresh through Metro. Changes to Swift, native dependencies, or native configuration require rebuilding the installed app. Expo Go cannot load the custom Swift scanner module, so the development build is the recommended workflow from the start. [Expo setup](https://docs.expo.dev/develop/development-builds/introduction/).

TestFlight is supported: configure the team's Apple Developer/App Store Connect and Expo EAS project, produce a signed production build, submit it, and invite testers. A production build bundles the UI and does not need Metro/the Mac. External testing can require Apple's beta review. This repository has not been connected to EAS or TestFlight yet. [Expo submission guide](https://docs.expo.dev/submit/ios/), [Apple TestFlight guide](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview).

```sh
npm run typecheck
npm test
```

See [integration handoff](../docs/frontend-flow-and-handoff.md) and [native camera module](modules/signloop-camera/README.md). Actual capture, permission changes, and skeleton alignment need verification on a physical iPhone. Android capture is not implemented. Live translation, continuous speech backpressure, ElevenLabs audio, and native lip-sync remain integration work. Rebuild the development app once to include Expo GL; the 3D character and scanner need combined performance checks on a physical iPhone.
