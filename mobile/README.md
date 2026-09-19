# Signloop mobile

Expo / React Native Playroom screens: Home and Conversation, with transcript and correction sheets. Start conversation opens the **native Swift camera and MediaPipe hand tracker** on iPhone. Translation, the final 3D goose, and ElevenLabs are not connected yet. A separate sample conversation preserves the UI review flow; real hand detection never generates sample captions.

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

“Preview sample conversation” on Home runs a finite sample: framing → ready → draft → thinking → accepted phrase → silent voice preview. “Demo · try states” opens additional scenarios. Use the caption pencil to correct and the top-right menu to read the transcript, mute voice, or end. Back also confirms End. Transcript data clears on ending.

Fonts are bundled locally. The UI imports canonical `../design-system/` tokens/icons and respects system text size and Reduce Motion. The goose illustration is temporary.

Navigation uses native screen slides. Buttons use native-driver press/release motion; sheets remain mounted until their dismissal finishes, including when ending a conversation.

Expo's floating Tools button can overlap app controls in a development build. Drag it aside, or turn off “Tools button” in the Expo developer menu when reviewing the UI.

## Install on your iPhone

For daily development, connect and trust the iPhone, enable Developer Mode, and select your Apple signing team in Xcode. From `mobile/`, run `npm run ios -- --device` and select the phone. This installs **Signloop's own development build**. Run `npm start` on the Mac and connect from the phone on the same network. A free Personal Team can be used for local testing; paid membership is needed for distribution through TestFlight.

UI/TypeScript edits refresh through Metro. Changes to Swift, native dependencies, or native configuration require rebuilding the installed app. Expo Go cannot load the custom Swift scanner module, so the development build is the recommended workflow from the start. [Expo setup](https://docs.expo.dev/develop/development-builds/introduction/).

TestFlight is supported: configure the team's Apple Developer/App Store Connect and Expo EAS project, produce a signed production build, submit it, and invite testers. A production build bundles the UI and does not need Metro/the Mac. External testing can require Apple's beta review. This repository has not been connected to EAS or TestFlight yet. [Expo submission guide](https://docs.expo.dev/submit/ios/), [Apple TestFlight guide](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview).

```sh
npm run typecheck
npm test
```

See [integration handoff](../docs/frontend-flow-and-handoff.md) and [native camera module](modules/signloop-camera/README.md). Actual capture, permission changes, and skeleton alignment need verification on a physical iPhone. Android capture is not implemented. Live translation, continuous speech backpressure, ElevenLabs audio, and the final avatar remain integration work.
