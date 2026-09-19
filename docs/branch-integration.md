# Combined branch status

The `eldiiar` branch combines these fetched snapshots:

| Source | Snapshot | Destination |
| --- | --- | --- |
| `origin/main`, including `sunny` | `d1472f3` (`sunny`: `1fb8ad2`) | `mobile/`, design system, Expo camera wrapper |
| `origin/yeyito` | `9e1f7d2` | Native scanner, offline recognition experiments, backend and evaluation tools |
| `origin/sanvi-signloop` | `575074e` | Standalone `goose/` prototype |

The first two histories are merged. Sanvi's unrelated tree is imported under
`goose/` without `.env` or its history. This deliberately avoids introducing a
tracked credential or overwriting root documentation and app manifests.

## Shared camera resolution

- Both camera shells compile the same `CameraTracker.swift`.
- Gesture Recognizer replaces the old Hand Landmarker-only inference path.
- Expo's injectable model path and lock-protected capture lifecycle are retained.
- The newer capture timestamps, pacing, stale-result checks, local gesture filter,
  and callback interfaces are retained.
- The Expo pod includes the new cadence/freshness sources and packages the
  Gesture Recognizer model in its resource bundle.
- `npm run camera:assets` fetches both public MediaPipe assets and verifies the
  Gesture Recognizer checksum. Native bootstrap reuses that same script.
- The Expo wrapper runs a timer to expire stalled overlays.

## Boundaries that remain

This is a combined source tree, **not a claim of complete end-to-end integration**.

- `mobile/` remains Expo SDK 55; `goose/` remains Expo SDK 57.
- The goose, lip sync, and voice prototype are not connected to the consumer
  app's integration contracts yet.
- The Expo camera emits hand-tracking status, not accepted translations.
- Private research-model weights and datasets are not supplied by this merge.
  The native five-sign research engine is not compiled into the Expo camera pod.
- The goose's direct ElevenLabs client is development-only. Move credentials
  behind a backend before sharing a voice-enabled build. `EXPO_PUBLIC_*` values
  are public client-bundle data even when sourced from an ignored `.env`.
- Camera behavior and native linkage require an Xcode/device build. Pure Swift,
  Python, and TypeScript tests do not substitute for phone validation.

## Local checks

```sh
bash ios/scripts/test-core.sh
scripts/dev/signlooptest . backend
scripts/dev/signlooptest . native
(cd mobile && npm ci && npm run typecheck && npm test)
(cd goose && npm ci && npm run typecheck && npm test)
```

No model-provider requests, deployment, or credential copying are needed for
these checks.
