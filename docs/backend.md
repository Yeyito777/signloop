# Live sign estimates — zero setup in the app

The app is a **single full-screen camera**. Open it and the current possible sign
updates automatically. Pause/resume, camera switching, and a skeleton toggle are
the only controls. No backend settings screen, reference recording, saving, or
Analyze button.

## What actually runs

Camera → on-device MediaPipe → recent 1.2-second landmark window → local backend
→ Backboard / TypeSafe Jev → current possible sign.

- One request in flight, targeting approximately one per second. This is network
  inference, **not camera-frame-rate recognition**.
- Two matching results stabilize a displayed label. Unknown, hands leaving view,
  camera switching, pause and backgrounding clear old labels. Responses older
  than 2.5 seconds are discarded; stalled labels expire.
- No backlog: every request uses the latest window. Offline failures back off.
- Jev uses built-in **textual sign descriptions and geometric features**, not
  saved examples or a validated ASL model. There is no required training step.
- Candidate vocabulary: HELLO, YES, NO, I_LOVE_YOU, THANK_YOU, PLEASE, and UNKNOWN.
  Chin/chest-relative signs may be ambiguous without face/body landmarks and
  should be rejected. Scores are uncalibrated; 0.8/0.2 score/margin gates are
  experimental, not a statement of recognition accuracy.
- The UI calls it a **possible sign / live estimate**. Zero-shot recognition is
  unvalidated; testing actual signs, unknown gestures and a held-out signer is
  still needed. API connectivity does not establish sign accuracy.

Cerebras's guarded label-to-caption endpoint remains available for later phrase
assembly, but is **not on the current-sign hot path**: a language model should
not rewrite the label you are currently making or add extra latency.

## Developer launch and provisioning

Python 3.10+ standard library. Secrets stay in ignored mode-0600 `.env`:

```sh
cp .env.example .env
# Set BACKBOARD_API_KEY and a different random SIGNLOOP_BACKEND_TOKEN.
chmod 600 .env
python3 -m backend.server --host 0.0.0.0 --port 8787
```

After installing the signed app on the phone, provision it automatically:

```sh
python3 -m backend.pair_phone --device Yeyito
```

This copies a temporary connection file containing only the Mac's local URL and
the **separate LAN access token** into the app sandbox. On launch, the app stores
the token in Keychain and removes the temporary file. The Backboard key is never
put in the phone binary, sandbox or Keychain. Existing configured installations
also retain their connection. iOS may still require Camera/Local Network permission.

No user setup screen is necessary. The phone and Mac must be on a network that
permits local connections; LAN client isolation/firewall rules may block access.
This is a development backend, not a standalone/offline recognizer. Local HTTP
is for a trusted network only. Production deployment requires HTTPS and proper
service hosting. No production daemon is installed by these scripts.

For worktrees use `--env-file /private/path/.env` and a distinct port.

## Verified gateway

One Hack the North key supports both routes via:

```
POST https://app.backboard.io/api/threads/messages
X-API-Key: <server-only BACKBOARD_API_KEY>
```

- Jev: `llm_provider: typesafe`, `model_name: jev-latest` (resolved to
  `jev-1.13.0` in live tests). `system_one.state` carries observations;
  `system_one.questions.sign` is a choice question.
  Parse `system_one.answers.sign`, not free-form text.
- Cerebras: `llm_provider: cerebras`, `model_name: openai/gpt-oss-120b`.
  Tested with synthetic labels → `"Hello, thank you."`.
- The smaller catalog entry `meta-llama/llama-3.1-8b-instruct` returned HTTP 200
  with inference status FAILED / no available endpoint. Always check status,
  not only HTTP success. The fallback is not a small 8B model.

Sources:
https://docs.backboard.io/concepts/system-one
https://docs.backboard.io/concepts/models
https://docs.backboard.io/api-reference/threads/send-message

## API and privacy

`GET /health`: non-sensitive readiness only, not an upstream availability test.
Other endpoints require `Authorization: Bearer <SIGNLOOP_BACKEND_TOKEN>`:

| Route | Input | Result |
| --- | --- | --- |
| `GET /v1/status` | — | Vocabulary and experimental mode |
| `POST /v1/classify` | `frames` | `candidates`, `unknown`, `reason`, `model` |
| `POST /v1/caption` | `raw_signs` | Guarded text, raw labels, model |

Reference-save endpoints have been removed. Live frames/sign histories are not
written to disk. Only a short landmark window is held in memory.

No images or video are sent. While the app is active and unpaused, **landmark
coordinates are automatically sent to the Mac and Backboard/TypeSafe**. The
single-screen UI discloses cloud analysis. Pausing/backgrounding stops new
requests; an already submitted upstream call may finish.

Backboard calls disable memory and schedule best-effort deletion of the
thread/assistant created by each independent call. Cleanup runs on a bounded
background queue so it does not delay live results. Failures/abrupt shutdown may
leave gateway records; upstream processing/retention policies still apply.
**Do not promise zero provider retention.** Keys, payloads and error bodies are
not logged. No automatic recording/export is performed.

## Tests

```sh
python3 -m unittest backend.test_service -v
python3 -m backend.test_native        # Swift ↔ HTTP contract, mocked models
bash ios/scripts/test-core.sh        # normalization, buffer, live stabilization
python3 -m backend.probe              # opt-in paid live API connectivity checks
```

Synthetic test geometry is not reference data or proof of ASL recognition.
