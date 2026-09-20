# Sanvi's goose in Honk & Tell

Tap the goose on Home or in a conversation to play a three-second wing-and-body emote; tap it again
while it plays to stop. The shared renderer accepts an optional
`emote` request and `onEmoteEnd` callback independently of its activity/expression.
Speech preparation/playback, pause, sheets, backgrounding, and leaving the screen cancel the
action. Reduce Motion uses a short status message on Home and disables the
conversation's dance target. The standalone goose preview
uses the same tap interaction. The character's touch target supports keyboard and
screen-reader activation. See [the emote implementation notes](../../../docs/goose-emote-plan.md).

The canonical character source is now [`goose/src/`](../../../goose/src), imported on `main` from `origin/sanvi-signloop` through `341afb4`. The duplicate character under `mobile/src/avatar/` was removed when resolving the merge. Sanvi's geometry, poses, effects, and motion stay in `goose/src/components/goose/`.

The mobile adapter is [`GooseAvatar.tsx`](../integrations/GooseAvatar.tsx). Home, live capture, and the explicit UI demo use the same component identity. It maps listening → watching. The shared expression values are neutral, joy, sadness, anger, fear, and disgust; neutral has no emotional override. While listening, the goose follows fresh stable native expression events. During speech preparation and playback, it follows the frozen phrase expression. Pause, sheets, and unavailable/stale tracking return it to neutral. See [expression integration](../../../docs/goose-expression-integration.md).

## Shared rendering

- Mobile stays on Expo SDK 55. Metro resolves all shared-source dependencies from `mobile/node_modules`; it does not import the standalone Expo 57 runtime.
- All Three consumers use its ESM entry. The CommonJS shim calls Node-only `process.emitWarning`, which fails in Hermes. Restart Metro after resolver changes.
- `MrGoose` accepts optional `transparent`, `reducedMotion`, and `fallback` props. Its standalone background and text fallback remain the defaults; mobile supplies its own illustrated fallback and transparent stage.
- The native canvas detects software GL renderers. That preview uses one-third drawing dimensions, Lambert lighting, and at most 12 rendered frames per second while the animation clock continues normally. Hardware keeps the full surface and original Standard materials. No synchronous GL flushes run in the animation loop.
- Native multisampling is disabled; the hardware path already uses device pixel density. Straight alpha preserves the butter/blue background behind the character.
- The app forwards Reduce Motion, pause, sheets, and lifecycle state. Still poses close the beak. On-demand rendering always updates the final pose.
- Home and Conversation share one 320 × 440 logical-point stage. Navigation transforms its container. The software drawing surface is smaller without changing layout. Voice settings hides the stage.

The original frozen Simulator preview was traced to Apple Software Renderer taking roughly 1.5–2 seconds per full-quality frame, building up an asynchronous GL queue. The adaptive preview removes that backlog. Actual iPhone performance still requires a device check.

## Voice boundary

The live adapter retains `main`'s authenticated backend voice flow. `gooseLipSync` supplies the native player's current time and server-aligned gesture cues to the same character. Voice state begins at the actual playback callback, rather than while fetching audio. Cleanup checks clock ownership so an old request cannot reset newer playback.

The current native player has no amplitude envelope. Beak motion therefore uses the procedural speaking rhythm; gesture timing follows audio alignment. Accurate amplitude-driven mouth motion remains future work. The UI demo uses explicitly labelled silent playback.

Sanvi's `341afb4` adds PCM playback, chunked alignment, and phrase readiness without changing the idle animation. Its standalone web player schedules incoming chunks; its native player collects them before playing a WAV. The mobile app keeps `main`'s backend-proxied MP3 adapter and does not import the direct-provider streaming client or credentials.

## Validation

Run the mobile typecheck, mobile tests, shared goose tests, and iOS export after shared-source changes. Rebuild the development app for native dependency, Swift, or config changes. A physical iPhone is required to validate camera, audio, and hardware GL together.

After reconciliation, the mobile typecheck, 50 mobile tests, 38 shared-goose tests, Swift scanner checks, Expo dependency check, production iOS export, and Xcode Simulator build pass. Simulator review verifies launch, Home and Voice settings navigation, and the explicit Conversation demo. Earlier review also covered visible idle motion, the settled paused pose, Reduce Motion startup, emotions, larger text, and lifecycle recovery. Physical camera/audio/GL validation remains outstanding.
