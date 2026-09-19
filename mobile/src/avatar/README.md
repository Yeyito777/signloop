# Sanvi's goose in Signloop

Character source: `origin/sanvi-signloop`, commit `575074e` (September 19, 2026).
The character, procedural motion, and optional speech-envelope/gesture utilities come from that branch. Its standalone app shell, dependency manifest, voice requests/player, and environment files were not imported.

Sanvi owns the geometry, materials, poses, effects, and motion in `components/goose/`. Keep future character updates in this folder. App behavior belongs in `src/integrations/goose.tsx` and `goosePresentation.ts`.

Integration adjustments:

- Expo 55-compatible `expo-gl` and `expo-asset`; React Three Fiber 9 with React 19. No SDK upgrade.
- Metro resolves `three` to its ESM build for all consumers. Three 0.186's CommonJS shim calls Node's `process.emitWarning`, which is unavailable in React Native. Restart Metro after changing this resolver.
- The native canvas detects software GL renderers. That preview uses one-third drawing dimensions, Lambert lighting, and at most 12 rendered frames per second while the animation clock continues normally. Hardware rendering retains the full surface and original Standard materials. Pause/Reduce Motion still updates the final pose on demand. No synchronous GL flushes run in the animation loop.
- Transparent canvas/scene with straight alpha (`premultipliedAlpha: false`) so the character composites correctly over the app's butter background and blue Home shape. Native multisampling is disabled; the hardware path already draws at device pixel density.
- The app's Reduce Motion, pause, and sheet states are forwarded into the character. Backgrounding stops rendering; still poses close the beak.
- A rendering error boundary retains the illustrated fallback so captions and controls remain usable. Native GL crashes cannot be caught by a React boundary; validate on a physical iPhone.
- One 320 × 440 logical-point canvas remains mounted above routes and below sheets. Navigation transforms its container without resizing the drawing surface.
- `listening` maps to `watching`; `happy` maps to `joy`. Neutral and thoughtful have no emotional override. Thinking is an app activity, not inferred sadness/fear. During playback, emotion follows the phrase being played.

The optional `lipSync` ref remains available for the voice pass. It is not wired yet. The UI demo uses explicitly labeled silent playback; live camera mode has no speech adapter. The MPEG decoder in the imported utilities uses Web Audio, so native lip-sync needs a native envelope source or server-supplied timing before it can be considered connected.

Run `npm run ios` once after adding these native dependencies. Subsequent character/layout edits use Metro. In the simulator: Start conversation → Try the UI demo → Demo · try states includes thinking, all four emotions, and long captions. Pause and sheets show still poses.

## Validation

Typecheck, all 38 tests, iOS production JavaScript export, and the native iOS Simulator build pass. Simulator review covers clean launch, Home → Conversation, shared-stage rendering, sample captions and joy, larger system text, long-caption bounds. Idle movement was verified with successive Simulator captures; the settled paused pose remains identical. Reduce Motion startup was also exercised, and the Simulator preference was restored. Background/foreground returned to the same conversation in its expected paused state. The original frozen Simulator preview was traced to Apple Software Renderer taking roughly 1.5–2 seconds per PBR frame, which built up an asynchronous GL backlog. The adaptive preview removes that backlog; hardware performance still requires a phone check. Physical-device camera plus 3D performance and native voice/lip-sync remain unverified.

## Upstream check

Fetched `origin/sanvi-signloop` through `341afb4` (streaming voice). That change adds PCM playback, chunked alignment, and a phrase-readiness gate; it does not alter the scene or idle motion. `origin/main` already carries it under `goose/`. The standalone native PCM player collects chunks before playing a WAV, whereas its web player schedules chunks as they arrive. The voice experiment is not imported into this isolated UI branch.
