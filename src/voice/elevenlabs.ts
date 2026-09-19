import type { GooseEmotion } from '../components/goose/motion.ts';
import { voiceConfig } from './config.ts';
import { alignmentWithoutAudioTags, type SpeechAlignment } from './gestures.ts';

export const ELEVENLABS_MODEL_ID = 'eleven_v3';
export const ELEVENLABS_OUTPUT_FORMAT = 'mp3_44100_128';
export const ELEVENLABS_VOICE_SETTINGS = {
  stability: 0.85,
  similarity_boost: 0.9,
  style: 0,
  speed: 1,
  use_speaker_boost: true,
};

/** Stage directions for the cloned voice. None of these are words we sign. */
export const emotionTags = {
  joy: ['happily', 'excited'],
  sadness: ['sad', 'sighs', 'slowly'],
  anger: ['angry'],
  fear: ['worried', 'nervously'],
} as const satisfies Record<GooseEmotion, readonly string[]>;

export const emotionVoice = {
  joy: { stability: 0, similarity_boost: 0.68, style: 0.85, speed: 1.16, use_speaker_boost: true },
  sadness: { stability: 0.5, similarity_boost: 0.84, style: 0.55, speed: 0.76, use_speaker_boost: true },
  anger: { stability: 0, similarity_boost: 0.6, style: 0.92, speed: 1.08, use_speaker_boost: true },
  fear: { stability: 0, similarity_boost: 0.64, style: 0.78, speed: 1.2, use_speaker_boost: true },
} as const satisfies Record<GooseEmotion, typeof ELEVENLABS_VOICE_SETTINGS>;

export function seedForSpeechText(text: string, emotion: GooseEmotion = 'joy'): number {
  const material = `${emotion}:${text}`;
  let hash = 2166136261;
  for (let i = 0; i < material.length; i += 1) {
    hash ^= material.charCodeAt(i);
    hash = Math.imul(hash, 16777619);
  }
  return hash >>> 0;
}

export class VoiceError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'VoiceError';
  }
}

export function prepareSpeechText(text: string): string {
  const trimmed = text.trim();
  if (!trimmed) throw new VoiceError('Type something for Mr. Goose to say.');
  return trimmed;
}

/** What ElevenLabs actually hears. Captions and gestures still use the plain English. */
export function performanceText(text: string, emotion: GooseEmotion = 'joy'): string {
  const tags = emotionTags[emotion].map(tag => `[${tag}]`).join(' ');
  return `${tags} ${text}`;
}

export function buildSpeechRequest(text: string, voiceId: string, apiKey: string, emotion: GooseEmotion = 'joy') {
  const performed = performanceText(text, emotion);
  return {
    url: `https://api.elevenlabs.io/v1/text-to-speech/${encodeURIComponent(voiceId)}/with-timestamps?output_format=${ELEVENLABS_OUTPUT_FORMAT}`,
    headers: {
      'xi-api-key': apiKey,
      'Content-Type': 'application/json',
      Accept: 'application/json',
    },
    body: JSON.stringify({
      text: performed,
      model_id: ELEVENLABS_MODEL_ID,
      seed: seedForSpeechText(text, emotion),
      voice_settings: emotionVoice[emotion],
    }),
  };
}

export function buildMpegSpeechRequest(text: string, voiceId: string, apiKey: string, emotion: GooseEmotion = 'joy') {
  const request = buildSpeechRequest(text, voiceId, apiKey, emotion);
  return {
    ...request,
    url: `https://api.elevenlabs.io/v1/text-to-speech/${encodeURIComponent(voiceId)}?output_format=${ELEVENLABS_OUTPUT_FORMAT}`,
    headers: { ...request.headers, Accept: 'audio/mpeg' },
  };
}

export function messageForSpeechError(status?: number, detail?: { status?: string; message?: string }): string {
  if (detail?.status === 'missing_permissions' || /missing the permission text_to_speech/i.test(detail?.message ?? '')) {
    return 'This ElevenLabs key cannot do text-to-speech. Create a new key with Text to Speech enabled, put it in .env, and restart Expo.';
  }
  if (status === 401 || status === 403) return 'The ElevenLabs key or voice id was rejected.';
  if (status === 404) return 'That goose voice id was not found.';
  if (status === 429) return 'ElevenLabs asked us to wait a moment. Try again shortly.';
  if (status && status >= 500) return 'ElevenLabs is having trouble right now.';
  if (status) return 'Mr. Goose could not speak that line.';
  return 'Could not reach ElevenLabs. Check the network connection.';
}

export type SpokenClip = {
  buffer: ArrayBuffer;
  alignment?: SpeechAlignment;
};

export function bytesFromBase64(value: string): ArrayBuffer {
  if (typeof Buffer !== 'undefined') {
    const bytes = Buffer.from(value, 'base64');
    return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
  }
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
}

function alignmentFromBody(body: { alignment?: SpeechAlignment; normalized_alignment?: SpeechAlignment }): SpeechAlignment | undefined {
  const raw = body.alignment ?? body.normalized_alignment;
  if (!raw?.characters?.length) return undefined;
  if (raw.characters.length !== raw.character_start_times_seconds?.length) return undefined;
  if (raw.characters.length !== raw.character_end_times_seconds?.length) return undefined;
  const cleaned = alignmentWithoutAudioTags(raw);
  return cleaned.characters.length ? cleaned : undefined;
}

/** Turns English text into an MP3 buffer plus word timings. Future ASR can call this unchanged. */
export async function speakEnglish(text: string, signal?: AbortSignal, emotion: GooseEmotion = 'joy'): Promise<SpokenClip> {
  if (!voiceConfig.voiceConfigured) throw new VoiceError(voiceConfig.setupMessage);
  const request = buildSpeechRequest(prepareSpeechText(text), voiceConfig.voiceId, voiceConfig.apiKey, emotion);
  let response: Response;
  try {
    response = await fetch(request.url, { method: 'POST', headers: request.headers, body: request.body, signal });
  } catch (error) {
    if (signal?.aborted) throw error;
    throw new VoiceError(messageForSpeechError());
  }
  if (!response.ok) {
    const fallback = await fetchMpegClip(request.body, voiceConfig.voiceId, voiceConfig.apiKey, emotion, signal);
    if (fallback) return { buffer: fallback };
    throw new VoiceError(messageForSpeechError(response.status, await readErrorDetail(response)));
  }
  const body = await response.json() as { audio_base64?: string; alignment?: SpeechAlignment; normalized_alignment?: SpeechAlignment };
  if (!body.audio_base64) throw new VoiceError('Mr. Goose could not speak that line.');
  return { buffer: bytesFromBase64(body.audio_base64), alignment: alignmentFromBody(body) };
}

async function fetchMpegClip(body: string, voiceId: string, apiKey: string, emotion: GooseEmotion, signal?: AbortSignal): Promise<ArrayBuffer | undefined> {
  const request = buildMpegSpeechRequest('', voiceId, apiKey, emotion);
  request.body = body;
  const response = await fetch(request.url, { method: 'POST', headers: request.headers, body: request.body, signal });
  if (!response.ok) return undefined;
  return response.arrayBuffer();
}

async function readErrorDetail(response: Response): Promise<{ status?: string; message?: string } | undefined> {
  try {
    const body = await response.json() as { detail?: { status?: string; message?: string } };
    return body.detail;
  } catch {
    return undefined;
  }
}
