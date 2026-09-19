"""ElevenLabs speech adapter.  Keys and speech text never leave this process except to ElevenLabs."""
from __future__ import annotations

import base64
import json
import math
import urllib.error
import urllib.parse
import urllib.request

from .service import ServiceError

ELEVENLABS_URL = "https://api.elevenlabs.io/v1/text-to-speech/"
MODEL_ID = "eleven_v3"
OUTPUT_FORMAT = "mp3_44100_128"
MAX_TEXT_CHARACTERS = 500
MAX_AUDIO_BYTES = 8 * 1024 * 1024
MAX_AUDIO_BASE64_CHARACTERS = ((MAX_AUDIO_BYTES + 2) // 3) * 4
# This admits a maximum-size audio field plus a bounded amount of timestamp data.
MAX_UPSTREAM_RESPONSE_BYTES = MAX_AUDIO_BASE64_CHARACTERS + 1_000_000
EMOTIONS = ("joy", "sadness", "anger", "fear")

VOICE_SETTINGS = {
    "joy": {"stability": 0, "similarity_boost": 0.68, "style": 0.85, "speed": 1.16,
            "use_speaker_boost": True},
    "sadness": {"stability": 0.5, "similarity_boost": 0.84, "style": 0.55, "speed": 0.76,
                "use_speaker_boost": True},
    "anger": {"stability": 0, "similarity_boost": 0.6, "style": 0.92, "speed": 1.08,
              "use_speaker_boost": True},
    "fear": {"stability": 0, "similarity_boost": 0.64, "style": 0.78, "speed": 1.2,
             "use_speaker_boost": True},
}
EMOTION_TAGS = {
    "joy": ("happily", "excited"),
    "sadness": ("sad", "sighs", "slowly"),
    "anger": ("angry",),
    "fear": ("worried", "nervously"),
}


class _NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Reject redirects so the ElevenLabs key is never sent to a new origin."""

    def http_error_302(self, request, response, code, message, headers):
        raise urllib.error.HTTPError(request.full_url, code, message, headers, response)

    http_error_300 = http_error_301 = http_error_303 = http_error_307 = http_error_308 = http_error_302


# Do not use urllib.request.urlopen here: its default opener follows redirects
# and would replay the xi-api-key header at the Location origin.
_PROVIDER_OPENER = urllib.request.build_opener(_NoRedirectHandler())


def seed_for_speech_text(text: str, emotion: str) -> int:
    """Match JavaScript's FNV-1a-like seedForSpeechText, including UTF-16 units."""
    value = 2166136261
    encoded = f"{emotion}:{text}".encode("utf-16-le")
    for index in range(0, len(encoded), 2):
        unit = encoded[index] | (encoded[index + 1] << 8)
        value = ((value ^ unit) * 16777619) & 0xffffffff
    return value


def validate_speech_input(text: object, emotion: object = "joy") -> tuple[str, str]:
    if not isinstance(text, str):
        raise ServiceError("speech", "Speech text must be a string.")
    if len(text) > MAX_TEXT_CHARACTERS:
        raise ServiceError("speech", f"Speech text must be at most {MAX_TEXT_CHARACTERS} characters.")
    text = text.strip()
    if not text:
        raise ServiceError("speech", "Speech text must not be empty.")
    try:
        # json.loads permits escaped lone UTF-16 surrogates. They are not safe
        # to send to the provider or hash using the JavaScript-compatible seed.
        text.encode("utf-8")
    except UnicodeError:
        raise ServiceError("speech", "Speech text must contain valid Unicode.") from None
    if not isinstance(emotion, str) or emotion not in EMOTIONS:
        raise ServiceError("speech", "Emotion must be joy, sadness, anger, or fear.")
    return text, emotion


def _alignment(value: object) -> dict | None:
    if value is None:
        return None
    if not isinstance(value, dict):
        raise ValueError()
    characters = value.get("characters")
    starts = value.get("character_start_times_seconds")
    ends = value.get("character_end_times_seconds")
    if not isinstance(characters, list) or not isinstance(starts, list) or not isinstance(ends, list):
        raise ValueError()
    if len(characters) != len(starts) or len(characters) != len(ends):
        raise ValueError()
    # A timestamp entry corresponds to one returned character.  This also bounds
    # parsing work independently of an unusual but otherwise small JSON response.
    if len(characters) > MAX_TEXT_CHARACTERS * 2 + 128:
        raise ValueError()
    for character, start, end in zip(characters, starts, ends):
        if not isinstance(character, str):
            raise ValueError()
        if type(start) not in (int, float) or type(end) not in (int, float):
            raise ValueError()
        if not math.isfinite(start) or not math.isfinite(end) or start < 0 or end < start:
            raise ValueError()
    return {"characters": characters, "character_start_times_seconds": starts,
            "character_end_times_seconds": ends}


class ElevenLabsVoice:
    """A single, fixed-origin ElevenLabs text-to-speech client; it never retries."""

    def __init__(self, api_key: str, voice_id: str, timeout: float = 20):
        if not api_key or not voice_id:
            raise ServiceError("config", "ElevenLabs speech is not configured.", 503)
        self.api_key = api_key
        self.voice_id = voice_id
        self.timeout = timeout

    def speak(self, text: object, emotion: object = "joy") -> dict:
        text, emotion = validate_speech_input(text, emotion)
        tags = " ".join(f"[{tag}]" for tag in EMOTION_TAGS[emotion])
        payload = {
            "text": f"{tags} {text}",
            "model_id": MODEL_ID,
            "seed": seed_for_speech_text(text, emotion),
            "voice_settings": VOICE_SETTINGS[emotion],
        }
        voice_id = urllib.parse.quote(self.voice_id, safe="")
        url = f"{ELEVENLABS_URL}{voice_id}/with-timestamps?output_format={OUTPUT_FORMAT}"
        request = urllib.request.Request(
            url, data=json.dumps(payload, allow_nan=False).encode("utf-8"),
            headers={"xi-api-key": self.api_key, "Content-Type": "application/json",
                     "Accept": "application/json"}, method="POST")
        try:
            with _PROVIDER_OPENER.open(request, timeout=self.timeout) as response:
                declared_size = response.headers.get("Content-Length")
                if declared_size is not None:
                    try:
                        declared_size = int(declared_size)
                        if not 0 <= declared_size <= MAX_UPSTREAM_RESPONSE_BYTES:
                            raise ValueError()
                    except ValueError:
                        raise ServiceError("upstream", "Invalid ElevenLabs response.", 502) from None
                raw = response.read(MAX_UPSTREAM_RESPONSE_BYTES + 1)
                if len(raw) > MAX_UPSTREAM_RESPONSE_BYTES:
                    raise ServiceError("upstream", "Oversized ElevenLabs response.", 502)
                result = json.loads(raw, parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
        except ServiceError:
            raise
        except urllib.error.HTTPError as error:
            # Provider error bodies can contain request data or account details.
            error.close()
            raise ServiceError("upstream_http", f"ElevenLabs returned HTTP {error.code}.", 502) from None
        except (urllib.error.URLError, TimeoutError, OSError, UnicodeError, ValueError, json.JSONDecodeError):
            raise ServiceError("upstream", "ElevenLabs connection or response failed.", 502) from None
        try:
            if not isinstance(result, dict):
                raise ValueError()
            audio_base64 = result.get("audio_base64")
            if not isinstance(audio_base64, str) or not audio_base64:
                raise ValueError()
            if len(audio_base64) > MAX_AUDIO_BASE64_CHARACTERS:
                raise ValueError()
            audio = base64.b64decode(audio_base64.encode("ascii"), validate=True)
            if not audio or len(audio) > MAX_AUDIO_BYTES:
                raise ValueError()
            alignment_value = result.get("alignment")
            if alignment_value is None:
                alignment_value = result.get("normalized_alignment")
            alignment = _alignment(alignment_value)
        except (ValueError, UnicodeError, TypeError):
            raise ServiceError("upstream_schema", "Unexpected ElevenLabs response.", 502) from None
        response = {"audio_base64": audio_base64}
        if alignment is not None:
            response["alignment"] = alignment
        return response
