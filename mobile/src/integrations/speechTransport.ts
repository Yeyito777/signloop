import { backendOrigin, type VoiceSettings } from './voiceSettings.ts';
import { toByteArray } from 'base64-js';
import { assertNotAborted } from './abort.ts';
import { alignmentWithoutAudioTags, type SpeechAlignment } from '../../../goose/src/voice/gestures.ts';

// Pure transport: test without React Native, audio hardware, secrets, or paid calls.
export type SpeechClip = { audio: Uint8Array; alignment?: SpeechAlignment };
const MAX_BASE64 = 12_000_000;

export function validateAlignment(value: unknown): SpeechAlignment | undefined {
  if (!value || typeof value !== 'object') return undefined;
  const v = value as SpeechAlignment;
  if (!Array.isArray(v.characters) || !Array.isArray(v.character_start_times_seconds)
    || !Array.isArray(v.character_end_times_seconds) || v.characters.length > 2000
    || v.characters.length !== v.character_start_times_seconds.length
    || v.characters.length !== v.character_end_times_seconds.length) return undefined;
  if (!v.characters.every((c, i) => typeof c === 'string' && c.length <= 8
    && Number.isFinite(v.character_start_times_seconds[i]) && Number.isFinite(v.character_end_times_seconds[i])
    && v.character_start_times_seconds[i] >= 0 && v.character_end_times_seconds[i] <= 90
    && v.character_end_times_seconds[i] >= v.character_start_times_seconds[i]
    && (i === 0 || v.character_start_times_seconds[i] >= v.character_start_times_seconds[i - 1]))) return undefined;
  return alignmentWithoutAudioTags(v);
}

export async function fetchSpeech(text: string, settings: VoiceSettings, signal: AbortSignal, request: typeof fetch = fetch): Promise<SpeechClip> {
  if (!settings.enabled) throw new Error('Enable text-to-voice uploads in Settings first.');
  const origin = backendOrigin(settings.url);
  if (settings.token.trim().length < 24) throw new Error('Enter the backend access token in Settings.');
  if (!text.trim() || text.length > 500) throw new Error('Speech needs 1–500 characters.');
  assertNotAborted(signal);
  const response = await request(`${origin}/v1/speech`, {
    method: 'POST', signal, redirect: 'error',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${settings.token.trim()}` },
    body: JSON.stringify({ text: text.trim(), emotion: 'joy' }),
  });
  assertNotAborted(signal);
  if (!response.ok) throw new Error(response.status === 401 ? 'The backend access token was rejected.'
    : response.status === 503 ? 'Voice is not configured on the backend.' : 'Voice request failed. Try again.');
  const declared = Number(response.headers.get('content-length'));
  if (declared > MAX_BASE64 + 100_000) throw new Error('Voice response is too large.');
  const raw = await response.text();
  assertNotAborted(signal);
  if (raw.length > MAX_BASE64 + 100_000) throw new Error('Voice response is too large.');
  const value = JSON.parse(raw) as { audio_base64?: unknown; alignment?: unknown };
  const encoded = value.audio_base64;
  if (typeof encoded !== 'string' || !encoded.length || encoded.length > MAX_BASE64
    || encoded.length % 4 !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(encoded)) throw new Error('Invalid voice response.');
  const bytes = toByteArray(encoded);
  return { audio: bytes, alignment: validateAlignment(value.alignment) };
}
