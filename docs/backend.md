# Experimental Jev → Cerebras backend

## Verified route (2026-09-19)

The Hack the North Backboard key can access **both** providers. No direct Cerebras
key is needed. Runtime API calls use:

```
POST https://app.backboard.io/api/threads/messages
X-API-Key: <server-only BACKBOARD_API_KEY>
```

- **Jev:** `llm_provider: typesafe`, `model_name: jev-latest`. Resolved to
  `jev-1.13.0` in a live test. Questions go in `system_one.questions`; landmark
  observations and references go in `system_one.state`. Decisions are parsed from
  `system_one.answers.sign` (`type: choice`, `choice`, `probabilities`).
- **Cerebras:** `llm_provider: cerebras`, `model_name: openai/gpt-oss-120b`.
  This route was tested successfully with synthetic `HELLO, THANK_YOU` labels,
  producing `"Hello, thank you."`.
- The catalog's smallest Cerebras entry, `meta-llama/llama-3.1-8b-instruct`, failed
  with an HTTP-200 response whose inference status was **FAILED** / no available
  endpoint. The implementation checks status/provider, not just HTTP success.
  GPT-OSS-120B is a working fallback, **not a small 8B model**. Change
  `CEREBRAS_MODEL` only after testing the alternative.

Live catalogs: `GET /models/providers` and `GET /models?provider=cerebras`.
No unsupported top-level `mode`, `temperature`, `max_tokens` or `response_format`
fields are sent to Jev. Typed System One questions select its execution mode.

Documentation:
- https://docs.backboard.io/concepts/system-one
- https://docs.backboard.io/concepts/models
- https://docs.backboard.io/api-reference/threads/send-message

**These tests prove API connectivity and schema handling, not ASL accuracy.**

## Run locally

Python 3.10+ standard library only. No pip dependencies.

```sh
cp .env.example .env
# Edit .env securely: BACKBOARD_API_KEY and a DIFFERENT random
# SIGNLOOP_BACKEND_TOKEN (at least 24 characters). Never commit real values.
chmod 600 .env
python3 -m unittest backend.test_service -v
python3 -m backend.test_native           # Swift ↔ HTTP contract test; mocked models
python3 -m backend.probe                 # live API calls / small usage charge
python3 -m backend.server                # loopback-only, port 8787
```

To connect the phone on your trusted Wi-Fi network:

```sh
python3 -m backend.server --host 0.0.0.0 --port 8787
scutil --get LocalHostName
```

Open **Connect** in the app's transcript card. Set
`http://<LocalHostName>.local:8787`, enter the **backend access token**, and test
the connection. Allow iOS Local Network access if asked. The Backboard key never
goes to the phone. The separate access token is stored in the iPhone Keychain.
Local HTTP is development-only; use a TLS reverse proxy for deployment. This
stdlib development server is not intended to be public-facing.

An optional `signloop://connect?url=<encoded-url>&token=<encoded-access-token>`
link configures the connection and opens settings, but **never enables uploads**.
Treat connection links as credentials; don't publish them.

## Try an actual gesture

1. Enable **Allow gesture uploads this session** in Backend settings.
2. Choose a reference label among HELLO, THANK_YOU, YES, NO, PLEASE.
3. Have someone who knows that ASL sign perform it with their hands in frame.
   Confirm the label and tap **Save last 2 seconds**. The camera keeps running
   behind the settings sheet. Saving replaces the example for that label.
4. Add the remaining signs. Examples are user-labelled, not independently
   validated; don't record invented approximations or call them validated ASL.
5. Return to the camera. Perform **one sign**, then tap **Analyze gesture**.
   That explicit tap defines a segment from the preceding two-second window.
6. Only a supported, sufficiently separated Jev match adds a raw label.
   Lower your hands before intentionally repeating a sign. Repeated held
   detections are suppressed.
7. Cerebras formats the ordered labels. A meaning guard checks the exact glossary
   word sequence; altered meanings fall back to literal labels. On provider error,
   the app keeps the raw labels and shows the error rather than inventing output.
8. Test unsupported gestures, no hands, transitions and a **different signer**.
   Record misses/false positives before claiming a useful recognizer.

This is **explicitly triggered, manually segmented** recognition, not automatic
continuous ASL transcription. No temporal auto-segmentation is claimed.
With no references, the backend returns `unknown/no_references` without calling
Jev. Empty/no-hand windows are rejected locally. Probability-like Jev scores are
uncalibrated; the 0.8 score / 0.2 margin are experimental gates, not validated
accuracy guarantees. Face/body context is absent and may make signs ambiguous.

## API

`GET /health` is an unauthenticated, non-sensitive readiness check. It does not
check live upstream availability or reveal credentials. All other routes require
`Authorization: Bearer <SIGNLOOP_BACKEND_TOKEN>`:

| Route | Input | Result |
| --- | --- | --- |
| `GET /v1/references` | — | Saved labels and five-sign vocabulary |
| `POST /v1/references` | `label`, `human_confirmed: true`, `frames` | Save/replace an explicitly labelled reference |
| `DELETE /v1/references` | — | Delete locally saved reference coordinates |
| `POST /v1/classify` | `frames` | `candidates`, `unknown`, `reason`, `model` |
| `POST /v1/caption` | `raw_signs` | `text`, `raw_signs`, `polished`, `model` |

Frames use the native export schema: increasing `timestampMS`, zero to two hands,
each with `handedness` and 21 `joints` of x/y/z. Inputs are bounded to 90 frames,
three seconds, and 300 KB. Data is downsampled for the model while retaining
normalized joints, handedness, wrist position and palm scale.

## Privacy and deployment

- Camera images/video never leave the phone. Upload permission defaults off and
  turns off on backgrounding/pausing; sending and reference saving are explicit.
- Reference coordinates are saved only upon explicit request, in ignored
  `.runtime/backend/references.json`, mode 0600. The settings screen can delete them.
- Request bodies, keys, captions, and provider error bodies are not logged.
- Backboard calls set `memory: "off"` and use independent turns, but Backboard
  creates server-side thread/assistant records. **This is not zero retention**.
  Provider retention policies still apply; deleting local references does not
  erase already submitted provider messages.
- `.env` and `.runtime` are ignored and never copied into task worktrees or app
  bundles. Secrets may be supplied explicitly using `--env-file /private/path/.env`.
- Use only a trusted LAN for local HTTP. Don't expose this development server to
  the public internet. Stop it with Ctrl-C; there is no managed production service.

## Worktrees

```sh
scripts/dev/signlooptest backend-jev backend # offline mocked/unit HTTP tests
cd .worktrees/backend-jev
python3 -m backend.probe --env-file ../../.env
python3 -m backend.server --env-file ../../.env --port 8788
```

Choose a distinct port for parallel backend instances. Reference data defaults
to each checkout's own `.runtime/backend`. No secret copying, background service
startup, or phone deployment is performed by `signlooptest`.
