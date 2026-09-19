# Signloop frontend handoff

Sunny · September 19, 2026 · `sunny`

The Expo app in `mobile/` uses the [Playroom design system](../design-system/README.md). Keep Sunny's design and integration work on `sunny`. The selected Go big direction uses “You were saying?”, a large shared goose, open captions, and dark sheets.

## Routes and sheets

| Route | Contents |
|---|---|
| `/` | Home, shared 3D goose, Start conversation, Voice settings. No camera capture. |
| `/conversation` | Stable camera/goose/caption regions; native scanner by default. |
| `/settings` | Main's optional backend voice configuration and session consent. |

Transcript, correction, the conversation menu, and end confirmation remain local sheets within Conversation. Framing feedback belongs in the camera view. System text size and Reduce Motion are respected without duplicating those controls. There are no accounts, saved-history screens, tutorials, or goodbye screens.

Home retains one primary Start action. `/conversation?demo=1` explicitly selects the finite sample: framing → ready → draft → thinking → accepted sample caption → silent speech preview. Simulator camera guidance links to this demo. “Demo · try states” provides manual framing, emotion, and caption scenarios without making network requests.

## Conversation behavior

- Pause stops capture and current/queued speech. Resume starts a fresh framing generation. Backgrounding pauses the conversation and revokes voice-upload consent; returning requires Resume.
- Sheets temporarily stop capture and playback. Dismissal resumes framing if the conversation was previously active; an explicit pause remains paused. Correction playback waits for dismissal.
- Drafts and tentative candidates are never spoken. Live ILY estimates require explicit confirmation before becoming a caption. Holding a confirmed gesture does not repeat it; release permits a new confirmation.
- Correction edits the most recent accepted phrase and retains its original wording. Save & speak requests playback; with voice off, Save correction changes text only. Sign it again restarts framing.
- The transcript stays in memory. End clears it, releases capture, and returns Home.
- Capture generations, candidate expiry, and playback IDs reject stale callbacks. Accepted phrases play in order. Continuous ASL translation still needs a defined phrase-boundary and speech-backlog policy.

## Camera and recognition

[`CameraProps`](../mobile/src/integrations/contracts.ts) includes `active`, `captureId`, framing state, `onFraming`, and `onTranslation`. A native preview owns capture and processing together. Never open a second Expo camera over it.

The [Expo camera module](../mobile/modules/signloop-camera/README.md) compiles shared Swift sources from root `ios/Signloop/`. The merge retains `main`'s Gesture Recognizer, cadence/freshness checks, lifecycle handling, and tentative ILY events. A complete hand must be visible inside the actual crop for readiness. This does not establish lighting, distance, emotion, or full ASL confidence; unsupported diagnoses remain demo-only.

Live recognition is a limited public-model ILY handshape preview: extend thumb, index, and pinky, then confirm the proposed English. It is not validated general ASL translation. The separate native five-sign research engine and private weights are not compiled into the Expo camera pod. The camera view makes no network requests.

Expo generates its own `mobile/ios/`; preserve the root native project. Changes to Swift, podspecs, native dependencies, or Expo config require rebuilding the development app.

## Layout and animation

`SharedStage.tsx` renders one avatar above Home/Conversation and below sheets. `StageSlot` publishes measured bounds; transitions move the outer container while retaining the character. The stage is hidden on Voice settings. Its logical size stays 320 × 440, with a smaller drawing surface on software GL. Home clips scrolling artwork away from controls. Direct entry and Reduce Motion skip travel.

The conversation reserves roughly 45% camera, 30% goose, and 25% captions. Larger system text claims more caption space without shrinking the goose. Long captions, tentative confirmation, notices, and recovery actions scroll inside that region; edit/replay remain in its header. Candidate confirmation does not expand the region or overlay the character.

Framing presentation waits for 300 ms of stable readiness and 450 ms before changing other guidance; native/permission failures appear immediately. Raw scanner events still control recognition without this visual delay. Accepted captions stay visible through later drafts, framing loss, pause, and errors. Delivery labels distinguish preparing voice, actual speech, silent demo playback, interruption, and failure.

## Shared goose and voice

[`GooseAvatar`](../mobile/src/integrations/GooseAvatar.tsx) adapts the app's activity/emotion contract to the canonical character in `goose/src/`. Home, camera, and demo kits use the same component identity. Listening maps to watching, happy to joy; neutral/thoughtful do not assign an emotion. The mobile wrapper supplies transparency, the illustrated fallback, motion preferences, and `gooseLipSync`. See the [character handoff](../mobile/src/avatar/README.md).

Metro keeps mobile on Expo SDK 55 even if the standalone goose app has its Expo 57 dependencies installed. Both source trees resolve Three to the same ESM instance. The software-renderer preview retains the idle fix while hardware keeps Sanvi's original materials.

`VoiceAdapter.speak(text, signal, onPlaybackStart)` resolves after playback and aborts local audio on cancellation. The live kit uses `main`'s authenticated `/v1/speech` backend; the demo uses a labelled silent timer. Backend credentials/provider selection remain server-side. Voice settings requires explicit upload consent; confirmed or edited English is uploaded, never camera images or landmarks. Consent is held in memory and revoked on backgrounding.

The native MP3 player feeds its clock and alignment-based gesture cues to the goose. The beak currently uses procedural speech motion because no amplitude envelope is supplied. Native PCM streaming and general ASL translation remain future work. See [voice backend setup](voice-backend.md) and [combined branch status](branch-integration.md).

## Review

Use the [mobile run instructions](../mobile/README.md). Check Home → Start, Voice settings → Back, the explicit demo, pause/resume, correction with keyboard, transcript, mute, end/cancel, lifecycle, long captions, larger text, and Reduce Motion. Automated tests cover tentative confirmation, freshness, cancellation, queue order, voice consent, and lip-sync ownership. Physical iPhone validation is required for camera, audio, and hardware GL together; Android capture is not implemented.
