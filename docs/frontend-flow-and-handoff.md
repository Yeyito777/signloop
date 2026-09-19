# Signloop frontend handoff

Sunny · September 19, 2026 · `sunny`

Keep design, screens, animation, and subsequent integration work together on `sunny`.

The initial Expo app is in `mobile/`. It uses the approved [Playroom design system](../design-system/README.md). Screen layouts are ready for native review, not final approval. The older HTML board includes explorations outside the current MVP.

The selected visual direction is **Go big**, with **“You were saying?”** as the Home headline. Large artwork, open captions, dark sheets, and a continuous decorative loop refine the same routes and integration contracts. Sanvi’s 3D goose and its activity/emotion modes are integrated. Live recognition, ElevenLabs playback, and native lip-sync remain separate integration work.

## Two routes

| Route | Contents |
|---|---|
| `/` | Home, shared 3D goose, one Start conversation action. No camera capture. |
| `/conversation` | Stable vertical split: camera above, goose and captions below. |

Transcript, correction, the conversation menu, and end confirmation are local sheets within Conversation. Framing feedback belongs in the camera view. There is no preferences route, tutorial sequence, account, saved-history dashboard, or goodbye screen.

The menu contains transcript, correction, voice on/off, and end conversation. System text size and Reduce Motion are respected without duplicating them in a settings screen.

## Behavior implemented for review

- Home has one Start conversation action, entering Conversation with native hand tracking. For UI testing, `/conversation?demo=1` explicitly selects the demo: framing → ready → draft → thinking → accepted caption → silent speech preview.
- Pause stops capture, recognition callbacks, current speech, and queued speech. Resume starts a fresh framing check. Backgrounding the app pauses it; returning requires Resume.
- Opening a sheet temporarily stops capture and playback. Closing it resumes through framing if the user had been active; an explicit prior pause is preserved. This resumption behavior is a UX choice for review.
- Only accepted phrases enter the transcript and automatic speech. Drafts and uncertain phrases are never spoken. Stable phrase IDs suppress duplicate acceptance events.
- Correction edits the latest accepted phrase. Save & speak makes the change and requests playback; with voice off it becomes Save correction. The first original caption is retained. Sign it again restarts framing; the existing accepted transcript entry stays.
- Transcript is in memory for this conversation. End confirmation clearly says it will be cleared; End releases the session and returns Home. No disk storage or export yet.
- Losing framing invalidates unfinished recognition. An already accepted phrase may finish playing. Network failure cancels playback and requires retry; voice failure leaves readable text.
- Capture generations and playback IDs reject callbacks from stopped work. Accepted phrases play in order. The current queue is suitable for the finite demo; a live adapter needs an explicit latency/backlog policy before continuous use.

## Integration boundary

See [contracts.ts](../mobile/src/integrations/contracts.ts). `cameraKit` supplies the native camera, shared 3D avatar, and unconnected translation/voice adapters. `demoKit` uses the same 3D avatar with simulated camera, translation, and silent voice for explicit sample review. Screens know their contracts, not their implementation.

### Native camera / scanner

`CameraProps` includes `active`, `captureId`, current `framing` presentation state, and `onFraming(framing, captureId)`. A native preview owns capture and processing together. Mount it in the existing camera slot; never open an extra Expo camera over it.

Implemented in [`mobile/modules/signloop-camera/`](../mobile/modules/signloop-camera/README.md). The local Expo view compiles the existing Swift scanner directly through the root podspec. It honors `active=false`, unmount, and application lifecycle; late permission replies and inference publications are rejected after pause. Preview, MediaPipe inference, and the skeleton stay native. JS receives deduplicated status changes tagged with `captureId`.

The scanner uses **MediaPipe Hand Landmarker**, not an ASL classifier. A complete hand must be visible inside the actual split-screen crop to emit ready. That does not establish face visibility, lighting quality, distance, emotion, or sign confidence. Unsupported framing diagnoses remain demo-only. Camera permission, denied/Settings, startup failure/retry, and Simulator/unavailable states are implemented. The demo requests no permission.

Expo builds its own project under `mobile/ios/`. Preserve the root `ios/` scanner scaffold. Swift/native processing plus React Native UI is the intended division of work.

Merged `origin/main` at `66d403b`, including `BackendClient.swift`, `RemoteRecognition.swift`, and the Python backend. The Expo camera wrapper currently makes no network requests. The module exposes `getRecentFrames()` on its native view ref for the next recognition integration; the shared Swift `recentFrames()` remains available for a native adapter. The backend's “possible sign” is a tentative label, not a completed English phrase eligible for speech. Phrase boundaries/acceptance and the caption endpoint still need wiring. Validate recognition on a physical phone.

### Translation

`TranslationAdapter.start(captureId, emit)` returns a cancellation function. Events are draft, thinking, accepted phrase (stable ID, text, emotion), uncertain, or offline. Framing readiness is independent of language confidence. Connect the scanner/backend stream inside this layer, not inside screens.

On cancel, release sockets/subscriptions and discard unfinished work. The coordinator also ignores stale events. Backend secrets stay off the phone. Before live integration, agree on phrase boundaries, stable IDs, confidence rejection, and supported vocabulary.

### Shared stage and presentation

`src/ui/SharedStage.tsx` renders a single `Avatar` above the route contents and below the sheet portal. Home and Conversation reserve space using `StageSlot`; measured bounds animate the outer container. The render surface stays 320 × 440 logical points while its container moves/scales, so the transition does not remount the 3D renderer or resize its drawing surface every frame. Both kits should use the same avatar component to preserve that continuity. The Home viewport clips scrolling artwork away from controls. Direct entry works without a source frame; Reduce Motion skips movement.

`CameraGuidance` filters only displayed tracking status (300 ms stable ready, 450 ms changed guidance). Device/permission failures are immediate. Raw scanner events still control recognition cancellation without delay. The guidance only uses diagnoses emitted by the adapter; unsupported states remain explicit demo examples.

`CaptionPanel` keeps the most recently accepted phrase readable during the next draft, framing loss, pause, or errors. A first draft is labeled unspoken. Delivery labels distinguish queued, playing, completed, interrupted, muted and failed playback; the demo always labels simulated playback. The conversation reserves roughly 45% of available height for camera, 30% for the goose, and 25% for captions. Caption length never changes those regions. Larger OS text increases the caption allocation at the expense of camera space; the goose retains its height. Caption content/recovery actions scroll, while edit/replay remain in the caption header. Correction updates in place with a brief acknowledgment.

### Goose

`AvatarProps`: `mode` (idle, listening, thinking, speaking), `emotion` (neutral, happy, thoughtful, sadness, anger, fear), `reducedMotion`, and layout style. `GooseAvatar` adapts these to Sanvi’s `MrGoose` component; Home and both kits use that same component identity.

The procedural React Three Fiber character is imported from `sanvi-signloop` at `575074e`, using Expo 55-compatible GL dependencies. Listening maps to watching, happy maps to joy, and neutral/thoughtful have no emotional override. Thinking stays an app activity. The transparent stage preserves the app background. The character is decorative for accessibility; text communicates meaning. Motion stops for pause, sheets, backgrounding, and Reduce Motion. See [character handoff](../mobile/src/avatar/README.md) for source ownership and native lip-sync follow-up.

### Voice

`VoiceAdapter.speak(text, AbortSignal)` resolves after playback ends and rejects on failure. Abort must stop audio and outstanding requests. The current adapter is a **silent timer**, not ElevenLabs. Connect backend-generated ElevenLabs audio to a native player and drive speaking from actual playback. Add audio/viseme events when needed.

## Review

See [run instructions](../mobile/README.md). “Demo · try states” opens framing, goose thinking/emotions, uncertainty, disconnection, and long-caption scenarios. This control belongs to the demo kit and disappears in live mode.

Review Home → Start, automatic captions, pause/resume, correction with the keyboard, transcript, mute, end/cancel, background/foreground, long captions, larger text, and Reduce Motion. Reducer tests cover cancellation, late events, deduplication, queue ordering, correction, mute, and recovery.

Camera/permission behavior and skeleton alignment need physical iPhone validation. Simulator and unsigned iPhone compilation are checked. Recognition, actual audio/native lip-sync, and Android capture remain integration work. Combined camera/3D performance needs physical-device validation. Hand tracking does not recognize ASL.
