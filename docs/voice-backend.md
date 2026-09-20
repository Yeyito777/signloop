# Backend ElevenLabs speech proxy

The backend exposes an authenticated `POST /v1/speech` endpoint for the app's
text-to-speech feature.  It is intentionally the only component that reads
`ELEVENLABS_API_KEY` and `ELEVENLABS_VOICE_ID`; neither value belongs in Expo,
the iPhone app, source control, or a client-side configuration file.

## Configure and run

Copy `.env.example` to the local, uncommitted `.env`, generate a distinct
`SIGNLOOP_BACKEND_TOKEN` of at least 24 characters, and set:

```dotenv
ELEVENLABS_API_KEY=...
ELEVENLABS_VOICE_ID=...
```

The regular backend may have both Backboard and speech configured:

```sh
python3 -m backend.server --env-file .env
```

For a speech-only service (no `BACKBOARD_API_KEY`), use:

```sh
python3 -m backend.server --env-file .env --voice-only
```

In voice-only mode `/health` and authenticated `/v1/status` report that speech
is available and classification/captioning are unavailable. `/v1/classify` and
`/v1/caption` return `503`. If either ElevenLabs setting is absent, the server
can still run, but `/v1/speech` returns `503 speech_unavailable`.

Use `http://<LAN-host>:8787` only for trusted local/LAN development. For any
deployment outside that network, put the backend behind HTTPS and keep the
backend token in app memory only after the user has explicitly consented to
uploading speech text.

Client cancellation can stop the app from waiting for or using a response, but
it cannot retract text already submitted to ElevenLabs or guarantee cancellation
of an in-flight, billable provider request.

## API

All `/v1` routes require:

```http
Authorization: Bearer <SIGNLOOP_BACKEND_TOKEN>
```

`POST` routes also require:

```http
Content-Type: application/json
```

Request:

```json
{"text":"Hello, nice to meet you.","emotion":"joy"}
```

`text` is required, is trimmed, and must contain at most 500 characters.
`emotion` is optional and is one of `neutral`, `joy`, `sadness`, `anger`, `fear`,
or `disgust` (`neutral` is the default). Neutral adds no performance tags. The
backend adds the same Eleven v3 stage-direction
tags and per-emotion voice settings used by `goose/src/voice/elevenlabs.ts`.
It uses a fixed ElevenLabs HTTPS origin, a percent-encoded configured voice ID,
`eleven_v3`, and `mp3_44100_128`; clients cannot select an origin, key, voice,
or model.

The mobile client sends the expression attached to the completed phrase, rather
than reading the current face when requesting speech. Replay and text correction
retain that phrase's expression. These labels describe the demonstrator's taught
facial patterns; they are not estimates of inner feelings or ASL grammar.

Success response:

```json
{
  "audio_base64":"...",
  "alignment":{
    "characters":["H","i"],
    "character_start_times_seconds":[0.0,0.1],
    "character_end_times_seconds":[0.1,0.2]
  }
}
```

`alignment` is omitted when ElevenLabs does not provide it. The backend accepts
at most 8 MiB of decoded audio and rejects malformed, oversized, timed-out, or
unexpected provider responses with a safe `502` JSON error. It does not retry
provider failures, return provider error bodies, log speech text, or return
credentials. Provider redirects are rejected rather than followed, so the
ElevenLabs key is never replayed to a redirect target.

Run the mocked unit tests without making a provider or paid request:

```sh
python3 -m unittest backend.test_voice
```
