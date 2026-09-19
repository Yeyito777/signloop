# Mr. Goose

A small Expo + React Native + TypeScript character preview. The repository was empty, so this starts from the dependency versions in Expo's blank TypeScript template (SDK 57). No accounts, navigation, or backend.

There is a local ElevenLabs voice prototype on the preview screen. A text field stands in for English that ASR will later produce. `speakEnglish` in `src/voice/elevenlabs.ts` is the seam future ASR should call.

## Preview on an iPhone

1. Install Node.js 22.13+ and run `npm install` in this folder.
2. Install the current **Expo Go** app on your iPhone (it must support SDK 57).
3. Connect the computer and iPhone to the same Wi-Fi, then run `npm start`.
4. Scan the terminal QR code with the iPhone Camera and open it in Expo Go.

A development build is **not required**: React Three Fiber's native Canvas uses `expo-gl`, which is included in Expo Go. The character consists entirely of Three.js primitives; it needs no model assets or custom native code. If your Expo Go version doesn't support SDK 57, use a matching Expo Go release or a development build. See [Expo GL](https://docs.expo.dev/versions/v57.0.0/sdk/gl-view/) and [Expo Go compatibility](https://expo.dev/go).

`npm run web` opens a browser preview using the same meshes and animation. `npm run ios` opens an installed iOS Simulator; Xcode and an iOS simulator runtime are required. On the phone, use normal on-device debugging; remote JavaScript execution can interfere with Expo GL.

## Reuse and customize

```tsx
import { MrGoose } from './src/components/MrGoose';

// The parent must have a size. False holds the current pose; true resumes it.
<MrGoose animationEnabled={true} style={{ height: 450, flex: 0 }} />
```

- `src/components/goose/settings.ts`: all colors, movement amounts, periods, and blink timing.
- `src/components/goose/GooseScene.tsx`: rounded shape sizes/positions, front and fill lights, framing, and the soft ground shadow. The head, body, wings, eye groups, and upper/lower beak are separate. Each eye's two highlights are children of its blink group.
- `src/components/goose/motion.ts`: small pure functions for the idle pose and animation clock.
- `src/components/MrGoose.tsx`: reusable component, Canvas lifecycle, animation-enabled prop, and rendering fallback.
- `src/screens/GoosePreview.tsx`: safe-area screen, Pause/Resume, and the ASR-stand-in Speak control.
- `src/voice/elevenlabs.ts`: request builder and `speakEnglish` TTS call.
- `src/hooks/useGooseVoice.ts`: cache the MP3, play it with `expo-audio`, and stop or replace the clip.

## Goose voice (local prototype)

This is not real speech recognition. Type the English line ASR would have emitted, then tap **Speak**.

1. Copy `.env.example` to `.env`.
2. In the ElevenLabs website, open your custom goose voice and copy its **Voice ID**.
3. Paste your API key and that voice id:

```
EXPO_PUBLIC_ELEVENLABS_API_KEY=...
EXPO_PUBLIC_ELEVENLABS_VOICE_ID=...
```

4. Restart Expo so Metro picks up the env vars (`npm start`, or `npm run web`).

The key stays on this machine. Do not commit `.env` or ship this client-side key in a shared build. When real ASR exists, it should pass its English string into `speakEnglish` instead of the text field.

Animation uses frame deltas and a local clock, not timers. Pausing preserves the pose and switches Canvas to on-demand rendering; resuming continues from that pose. Backgrounding also stops continuous rendering. iOS Reduce Motion (Settings → Accessibility → Motion) takes priority over the button and resets to a still, open-eyed pose. Preference and lifecycle listeners are removed on unmount. React Three Fiber unregisters frame callbacks and disposes declarative geometries/materials when Canvas unmounts.

The contact shadow is made of softly layered transparent disks, avoiding an expensive real-time shadow map on a phone. Materials are matte except for the eyes. The responsive orthographic camera keeps the whole character in view.

## Checks

```sh
npm run typecheck
npm test
npx expo install --check
npx expo-doctor
npx expo export --platform ios --platform web
```

Verified during implementation:

- TypeScript passes; four motion tests pass (pause/resume continuity, delayed frame clamping, blink close/reopen, motion bounds).
- Expo dependency compatibility passes; Expo Doctor passes all 21 checks.
- Production iOS and web bundles export successfully.
- Browser preview renders at phone size. Paused character captures are identical; captures differ after Resume. Controls update correctly.

An actual iPhone runtime was **not** tested: this machine has no available iOS simulator runtime. On-device performance, OS Reduce Motion changes, background/foreground behavior, and unmount cleanup still need device validation. To check: leave it running for 30 seconds to see blinks, pause for several seconds, resume, enable Reduce Motion, then background/reopen the app. Three.js currently emits a harmless `Clock` deprecation warning from React Three Fiber in the browser; there were no runtime rendering errors.
