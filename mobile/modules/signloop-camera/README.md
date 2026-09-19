# Native camera handoff

This local Expo SDK 55 module embeds the shared Swift scanner in the Conversation camera slot. It owns one `AVCaptureSession` for the mirrored front preview and MediaPipe processing. Pixels never cross into JavaScript. No camera video or landmark data is uploaded by this module.

## Shared implementation

- `ios/Signloop/CameraTracker.swift`: capture, permissions, MediaPipe, bounded landmark buffer.
- `ios/Signloop/CaptureLifecycle.swift`: generation checks for delayed permissions/start/inference work.
- `ios/Signloop/CameraPreview.swift`: the shared portrait/aspect-fill preview view.
- `ios/Signloop/Recognition.swift`: landmark schema, normalization, buffer, coordinate mapping.
- This directory's `ios/`: Expo module and native view; native skeleton drawing and deduplicated status events.
- Root `SignloopCamera.podspec`: compiles both sets of sources into the Expo app without copying. CocoaPods pins the same MediaPipe 0.10.21 as the standalone scanner.

After modifying shared Swift files, rebuild the development app. If you add a new shared file, include it in the podspec's explicit source list. Regenerate the standalone Xcode project with its bootstrap script when needed; it remains a separate app.

## React Native contract

`SignloopCamera` accepts `active`, `captureId`, `showSkeleton`, standard view styles, and `onStatus`. Status payloads contain `captureId`, `status`, `handCount`, and a diagnostic `message`. The adapter validates the current generation before forwarding framing into the session reducer.

| Native status | Frontend meaning |
|---|---|
| `starting` | Requesting access or starting capture |
| `searching` | No complete tracked hand inside the visible crop |
| `tracking` | At least one complete hand inside the visible crop; not language confidence |
| `denied` | User/system denied camera access; show Settings |
| `unavailable` | Simulator; fallback wrapper also handles missing module/other platforms |
| `error` | Capture/model failure; show retry |

Pausing, opening a sheet, ending, or backgrounding stops capture. Returning from background requires Resume. A permission prompt temporarily makes iOS inactive; capture can continue after that prompt if the conversation is still active. A late permission reply or camera-interruption notification cannot restart an explicitly paused tracker.

## Connecting recognition next

The native view ref exposes:

```ts
getRecentFrames(): Promise<{ captureId: number; frames: LandmarkFrame[] }>
```

It returns the most recent 1.2 seconds from the native bounded buffer, or an empty array when capture stopped/the generation changed. Coordinates are image-normalized, portrait, mirrored for the front camera; z is relative depth. Handedness confidence is not sign confidence. The native skeleton uses the same aspect-fill math as the standalone app.

Keep at most one classification request in flight and request a fresh window after it completes. Cancel requests on pause/generation changes; reject stale results again on receipt. Keep provider API keys on the backend. You can also connect the existing Swift `RemoteRecognition` beside the tracker, avoiding landmark serialization through JS entirely. It is not compiled into this camera pod yet.

Expose tentative sign estimates separately from `TranslationEvent.accepted`. Only a completed, accepted English phrase belongs in the transcript/voice pipeline. `cameraKit` deliberately emits no translations and has no simulated successful voice playback.

## Build and check

From `mobile/`: `npm ci`, then `npm run ios`. For a connected phone use `npm run ios -- --device`. For a manual prebuild/pod install, first run `npm run camera:assets`. The downloaded model is ignored by Git and packaged in `SignloopCameraModels.bundle`.

Simulator checks native registration, screens, pause/resume, sheets, and the unavailable fallback. It cannot test actual camera frames. On an iPhone:

1. Open Start conversation; allow camera access and check that the preview starts.
2. Move one/two hands into view; confirm joint alignment and no success when hands leave the visible crop.
3. Pause/resume, open/close a sheet, background/return, and end. Check that camera use stops and no old readiness returns.
4. Deny permission, open Settings, grant it, return, and Resume. Also leave the conversation while a permission request is pending.
5. Confirm that hand detection produces no sample sentence, audio, or network request.

Core checks: `npm run typecheck`, `npm test`, and from the repository root `bash ios/scripts/test-core.sh`.
