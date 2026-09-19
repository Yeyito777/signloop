# Mobile app

Keep Sunny's work on the shared `sunny` branch. Do not create separate feature branches unless requested.

Use the installed Expo SDK 55 docs: https://docs.expo.dev/versions/v55.0.0/.
SDK 55 is intentional: the local Xcode 26.3 supports it. SDK 56/57 require Xcode 26.4+.

Reuse the canonical Playroom tokens and icons from `../design-system/`.
Keep camera capture, translation, voice, and avatar rendering behind the integration contracts.
The current app uses explicitly labeled demo adapters; never present them as real recognition.
Keep native scanner work in the existing root `ios/` intact; Expo generates its own `mobile/ios/`.
