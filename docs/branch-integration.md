# Combined branch status

The `eldiiar` branch combines these fetched snapshots:

| Source | Snapshot | Destination |
| --- | --- | --- |
| `origin/main`, including `sunny` | `d1472f3` (`sunny`: `1fb8ad2`) | `mobile/`, design system, Expo camera wrapper |
| `origin/yeyito` | `9e1f7d2` | Native scanner, offline recognition experiments, backend and evaluation tools |
| `origin/sanvi-signloop` | `341afb4` | `goose/` prototype and shared character sources |

The first two histories are merged. Sanvi's unrelated tree is imported under
`goose/` without `.env` or its history. This deliberately avoids introducing a
tracked credential or overwriting root documentation and app manifests.

## Shared camera resolution

- The Expo consumer app retains `CameraTracker.swift` and its Gesture Recognizer
  flow, including tentative ILY estimates and optional sign-engine callbacks.
- The standalone native app uses `SkeletonCameraTracker.swift` for synchronized
  hand, upper-body and face tracking. Its inspector does not classify signs.
- Both trackers use the lock-protected `CaptureLifecycle`, capture timestamps,
  pacing and stale-result checks; pausing invalidates pending permission replies
  and queued capture starts.
- Expo's injectable model path and lock-protected capture lifecycle are retained.
- The newer capture timestamps, pacing, stale-result checks, local gesture filter,
  and callback interfaces are retained.
- The Expo pod includes the new cadence/freshness sources and packages the
  Gesture Recognizer model in its resource bundle.
- `npm run camera:assets` fetches the hand and gesture models and verifies the
  Gesture Recognizer checksum. Native bootstrap reuses that script, verifies
  the hand model, and adds checksum-verified pose-lite and face models.
- The Expo wrapper runs a timer to expire stalled overlays.

## Unified live flow

The Expo app reuses the goose renderer through `GooseAvatar` and SDK-55-compatible
Fiber/Three/Expo GL packages. Native `onSign` events produce a tentative ILY
handshape candidate, not an automatically accepted translation. Confirmation
checks the capture generation and candidate freshness. A held confirmed sign
does not repeatedly create captions; release resets it.

With explicit foreground-session consent, confirmed or edited English goes to
authenticated `/v1/speech`; the backend alone calls ElevenLabs. No video or
landmarks go through this voice path. The mobile adapter uses bounded audio,
abort-aware playback, temporary-file cleanup, timing-based character gestures,
and owner-checked lip-sync cleanup. Settings and backend tokens stay in memory.
Backgrounding disables uploads; already submitted requests cannot be retracted.

## Boundaries that remain

This is a wired, limited end-to-end implementation, **not validated full ASL translation**.

- `mobile/` remains Expo SDK 55; `goose/` remains Expo SDK 57.
- Shared rendering code runs against SDK 55 dependencies. The standalone
  Expo 57 app remains independently usable; its direct-provider streaming
  experiments are not used by the secure mobile adapter.
- The Expo camera emits hand-tracking status and tentative ILY estimates;
  only explicit confirmation promotes one to a caption/voice request.
- Private research-model weights and datasets are not supplied by this merge.
  The native five-sign research engine is not compiled into the Expo camera pod.
- The standalone goose's direct ElevenLabs client is development-only.
  `EXPO_PUBLIC_*` values are public client-bundle data even when sourced from
  an ignored `.env`. The main mobile app does not import that client.
- Camera behavior and native linkage require an Xcode/device build. Pure Swift,
  Python, and TypeScript tests do not substitute for phone validation.

## Local checks

```sh
bash ios/scripts/test-core.sh
scripts/dev/signlooptest . backend
scripts/dev/signlooptest . native
(cd mobile && npm ci && npm run typecheck && npm test)
(cd goose && npm ci && npm run typecheck && npm test)
python3 -m unittest backend.test_voice
(cd mobile && npx expo install --check && npx expo export --platform ios --output-dir dist-integration)
```

No model-provider requests, deployment, or credential copying are needed for
these checks.

An iOS JavaScript/Hermes export is not an Xcode native build. This integration
environment has Command Line Tools but no configured full Xcode; native
device linkage and live camera/audio/GL behavior still need a phone smoke test.
