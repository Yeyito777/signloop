# Sanvi's goose in Signloop

Character source: `origin/sanvi-signloop`, commit `575074e` (September 19, 2026).
The character, procedural motion, and optional speech-envelope/gesture utilities come from that branch. Its standalone app shell, dependency manifest, voice requests/player, and environment files were not imported.

Sanvi owns the geometry, materials, poses, effects, and motion in `components/goose/`. Keep future character updates in this folder. App behavior belongs in `src/integrations/goose.tsx` and `goosePresentation.ts`.

Integration adjustments:

- Expo 55-compatible `expo-gl` and `expo-asset`; React Three Fiber 9 with React 19. No SDK upgrade.
- Metro resolves `three` to its ESM build for all consumers. Three 0.186's CommonJS shim calls Node's `process.emitWarning`, which is unavailable in React Native. Restart Metro after changing this resolver.
- The native canvas drains Expo GL’s startup queue across its first three frames; on-demand rendering also completes those startup frames. This avoids a blank surface during asynchronous native initialization without blocking steady animation. Keep this compatibility workaround in `GooseCanvas.tsx`, outside the character scene.
- Transparent canvas/scene with straight alpha (`premultipliedAlpha: false`) so the character composites correctly over the app's butter background and blue Home shape. This uses straight alpha in addition to the native startup synchronization.
- The app's Reduce Motion, pause, and sheet states are forwarded into the character. Backgrounding stops rendering; still poses close the beak.
- A rendering error boundary retains the illustrated fallback so captions and controls remain usable. Native GL crashes cannot be caught by a React boundary; validate on a physical iPhone.
- One 320 × 440 logical-point canvas remains mounted above routes and below sheets. Navigation transforms its container without resizing the drawing surface.
- `listening` maps to `watching`; `happy` maps to `joy`. Neutral and thoughtful have no emotional override. Thinking is an app activity, not inferred sadness/fear. During playback, emotion follows the phrase being played.

The optional `lipSync` ref remains available for the voice pass. It is not wired yet. The UI demo uses explicitly labeled silent playback; live camera mode has no speech adapter. The MPEG decoder in the imported utilities uses Web Audio, so native lip-sync needs a native envelope source or server-supplied timing before it can be considered connected.

Run `npm run ios` once after adding these native dependencies. Subsequent character/layout edits use Metro. In the simulator: Start conversation → Try the UI demo → Demo · try states includes thinking, all four emotions, and long captions. Pause and sheets show still poses.

## Validation

Typecheck, all 38 tests, iOS production JavaScript export, and the native iOS Simulator build pass. Simulator review covers clean launch, Home → Conversation, shared-stage rendering, sample captions and joy, larger system text, long-caption bounds. Startup with Reduce Motion configured was also exercised. The simulator development client reloaded to Home during a background/foreground check; session preservation across backgrounding still needs physical-device validation. Physical-device camera plus 3D performance and native voice/lip-sync remain unverified.
