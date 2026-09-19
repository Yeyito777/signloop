# Signloop frontend handoff

Sunny · September 19, 2026 · `sunny`

Keep design, screens, animation, and subsequent integration work together on `sunny`.

The initial Expo app is in `mobile/`. It uses the approved [Playroom design system](../design-system/README.md). Screen layouts are ready for native review, not final approval. The older HTML board includes explorations outside the current MVP.

## Two routes

| Route | Contents |
|---|---|
| `/` | Home, temporary goose, one Start conversation action. No camera capture. |
| `/conversation` | Stable vertical split: camera above, goose and captions below. |

Transcript, correction, the conversation menu, and end confirmation are local sheets within Conversation. Framing feedback belongs in the camera view. There is no preferences route, tutorial sequence, account, saved-history dashboard, or goodbye screen.

The menu contains transcript, correction, voice on/off, and end conversation. System text size and Reduce Motion are respected without duplicating them in a settings screen.

## Behavior implemented for review

- Start enters Conversation. The demo moves through framing → ready → draft → thinking → accepted caption → silent speech preview.
- Pause stops capture, recognition callbacks, current speech, and queued speech. Resume starts a fresh framing check. Backgrounding the app pauses it; returning requires Resume.
- Opening a sheet temporarily stops capture and playback. Closing it resumes through framing if the user had been active; an explicit prior pause is preserved. This resumption behavior is a UX choice for review.
- Only accepted phrases enter the transcript and automatic speech. Drafts and uncertain phrases are never spoken. Stable phrase IDs suppress duplicate acceptance events.
- Correction edits the latest accepted phrase. Save & speak makes the change and requests playback; with voice off it becomes Save correction. The first original caption is retained. Sign it again restarts framing; the existing accepted transcript entry stays.
- Transcript is in memory for this conversation. End confirmation clearly says it will be cleared; End releases the session and returns Home. No disk storage or export yet.
- Losing framing invalidates unfinished recognition. An already accepted phrase may finish playing. Network failure cancels playback and requires retry; voice failure leaves readable text.
- Capture generations and playback IDs reject callbacks from stopped work. Accepted phrases play in order. The current queue is suitable for the finite demo; a live adapter needs an explicit latency/backlog policy before continuous use.

## Integration boundary

See [contracts.ts](../mobile/src/integrations/contracts.ts). `demoKit` supplies four replaceable pieces. Screens know their contracts, not their implementation.

### Native camera / scanner

`CameraProps` includes `active`, `captureId`, current `framing` presentation state, and `onFraming(framing, captureId)`. A native preview owns capture and processing together. Mount it in the existing camera slot; never open an extra Expo camera over it.

Wrap the existing Swift capture/MediaPipe code with an Expo native view/module. Honor `active=false` immediately and release resources on unmount. Return normalized, throttled status events to JS; keep frames and heavy processing native. Tag asynchronous events with their originating generation. Compute framing from observations, not from the incoming presentation state.

The root `ios/` app uses **MediaPipe Hand Landmarker**, not an ASL classifier. It does not establish face visibility, lighting quality, or distance yet. The preview includes those states for design review, but live adapters must emit only diagnostics they support. Add camera permission and denied/unavailable handling when wiring capture; the demo requests no permission.

Expo builds its own project under `mobile/ios/`. Preserve the root `ios/` scanner scaffold. Swift/native processing plus React Native UI is the intended division of work.

Remote checked before this push: `origin/main` at `66d403b` also contains `BackendClient.swift`, `RemoteRecognition.swift`, and a Python backend for live Jev sign estimates. These newer commits are not merged into this UI branch. For the next camera-integration step on `sunny`, bring in that work and reuse the native capture/backend components. Its current “possible sign” is a tentative label, not a completed English phrase eligible for speech. Phrase boundaries/acceptance and the existing caption endpoint need wiring separately. Validate recognition on a physical phone.

### Translation

`TranslationAdapter.start(captureId, emit)` returns a cancellation function. Events are draft, thinking, accepted phrase (stable ID, text, emotion), uncertain, or offline. Framing readiness is independent of language confidence. Connect the scanner/backend stream inside this layer, not inside screens.

On cancel, release sockets/subscriptions and discard unfinished work. The coordinator also ignores stale events. Backend secrets stay off the phone. Before live integration, agree on phrase boundaries, stable IDs, confidence rejection, and supported vocabulary.

### Goose

`AvatarProps`: `mode` (idle, listening, thinking, speaking), `emotion` (placeholder vocabulary), `reducedMotion`, and layout style. Replace the illustration with a 3D renderer through this interface.

Model format, renderer, expression vocabulary, clip names, and mouth synchronization remain open. Extend the contract together when assets arrive. The character is decorative for accessibility; text communicates meaning. Stop motion while paused/backgrounded. The placeholder does not implement facial emotions.

### Voice

`VoiceAdapter.speak(text, AbortSignal)` resolves after playback ends and rejects on failure. Abort must stop audio and outstanding requests. The current adapter is a **silent timer**, not ElevenLabs. Connect backend-generated ElevenLabs audio to a native player and drive speaking from actual playback. Add audio/viseme events when needed.

## Review

See [run instructions](../mobile/README.md). “Demo · try states” opens framing, uncertainty, disconnection, and long-caption scenarios. This control belongs to the demo kit and disappears in live mode.

Review Home → Start, automatic captions, pause/resume, correction with the keyboard, transcript, mute, end/cancel, background/foreground, long captions, larger text, and Reduce Motion. Reducer tests cover cancellation, late events, deduplication, queue ordering, correction, mute, and recovery.

Real camera/recognition quality, final 3D rendering, actual audio, Android behavior, and permissions need integration/device validation. This preview does not recognize ASL.
