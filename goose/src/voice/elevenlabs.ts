import type { GooseEmotion } from '../components/goose/motion.ts';
import { voiceConfig } from './config.ts';
import { alignmentWithoutAudioTags, mergeAlignment, type SpeechAlignment } from './gestures.ts';
import { pcm16ToFloat } from './pcm.ts';

export const ELEVENLABS_MODEL_ID = 'eleven_v3';
export const ELEVENLABS_OUTPUT_FORMAT = 'mp3_44100_128';
export const ELEVENLABS_STREAM_FORMAT = 'pcm_24000';
export const ELEVENLABS_STREAM_SAMPLE_RATE = 24_000;
export const ELEVENLABS_VOICE_SETTINGS = {
  stability: 0.85,
  similarity_boost: 0.9,
  style: 0,
  speed: 1,
  use_speaker_boost: true,
};

/** Stage directions for the cloned voice. None of these are words we sign. */
export const emotionTags = {
  neutral: [],
  joy: ['happily', 'excited'],
  sadness: ['sad', 'sighs', 'slowly'],
  anger: ['angry'],
  fear: ['worried', 'nervously'],
  disgust: ['disgusted'],
} as const satisfies Record<GooseEmotion, readonly string[]>;

export const emotionVoice = {
  neutral: { stability: 0.5, similarity_boost: 0.8, style: 0, speed: 1, use_speaker_boost: true },
  joy: { stability: 0, similarity_boost: 0.68, style: 0.85, speed: 1.16, use_speaker_boost: true },
  sadness: { stability: 0.5, similarity_boost: 0.84, style: 0.55, speed: 0.76, use_speaker_boost: true },
  anger: { stability: 0, similarity_boost: 0.6, style: 0.92, speed: 1.08, use_speaker_boost: true },
  fear: { stability: 0, similarity_boost: 0.64, style: 0.78, speed: 1.2, use_speaker_boost: true },
  disgust: { stability: 0.5, similarity_boost: 0.72, style: 0.7, speed: 0.92, use_speaker_boost: true },
} as const satisfies Record<GooseEmotion, typeof ELEVENLABS_VOICE_SETTINGS>;

export function seedForSpeechText(text: string, emotion: GooseEmotion = 'neutral'): number {
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
export function performanceText(text: string, emotion: GooseEmotion = 'neutral'): string {
  const tags = emotionTags[emotion].map(tag => `[${tag}]`).join(' ');
  return tags ? `${tags} ${text}` : text;
}

export function buildSpeechRequest(text: string, voiceId: string, apiKey: string, emotion: GooseEmotion = 'neutral') {
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

export function buildMpegSpeechRequest(text: string, voiceId: string, apiKey: string, emotion: GooseEmotion = 'neutral') {
  const request = buildSpeechRequest(text, voiceId, apiKey, emotion);
  return {
    ...request,
    url: `https://api.elevenlabs.io/v1/text-to-speech/${encodeURIComponent(voiceId)}?output_format=${ELEVENLABS_OUTPUT_FORMAT}`,
    headers: { ...request.headers, Accept: 'audio/mpeg' },
  };
}

export function buildStreamSpeechRequest(text: string, voiceId: string, apiKey: string, emotion: GooseEmotion = 'neutral') {
  const request = buildSpeechRequest(text, voiceId, apiKey, emotion);
  return {
    ...request,
    url: `https://api.elevenlabs.io/v1/text-to-speech/${encodeURIComponent(voiceId)}/stream/with-timestamps?output_format=${ELEVENLABS_STREAM_FORMAT}`,
  };
}

export type StreamSpeechChunk = {
  audio_base64?: string;
  alignment?: SpeechAlignment;
  normalized_alignment?: SpeechAlignment;
};

export function parseStreamLine(line: string): StreamSpeechChunk | undefined {
  const trimmed = line.trim();
  if (!trimmed || trimmed === '[DONE]') return undefined;
  const json = trimmed.startsWith('data:') ? trimmed.slice(5).trim() : trimmed;
  if (!json || json === '[DONE]') return undefined;
  try {
    return JSON.parse(json) as StreamSpeechChunk;
  } catch {
    return undefined;
  }
}

/** Pull complete JSON objects out of a buffer, even if ElevenLabs pretty-prints them. */
export function consumeStreamObjects(buffer: string): { rest: string; objects: StreamSpeechChunk[] } {
  const objects: StreamSpeechChunk[] = [];
  let i = 0;
  while (i < buffer.length) {
    const start = buffer.indexOf('{', i);
    if (start < 0) return { rest: '', objects };
    let depth = 0;
    let inString = false;
    let escape = false;
    let end = -1;
    for (let j = start; j < buffer.length; j += 1) {
      const ch = buffer[j];
      if (inString) {
        if (escape) escape = false;
        else if (ch === '\\') escape = true;
        else if (ch === '"') inString = false;
        continue;
      }
      if (ch === '"') {
        inString = true;
        continue;
      }
      if (ch === '{') depth += 1;
      else if (ch === '}') {
        depth -= 1;
        if (depth === 0) {
          end = j;
          break;
        }
      }
    }
    if (end < 0) return { rest: buffer.slice(start), objects };
    const parsed = parseStreamLine(buffer.slice(start, end + 1));
    if (parsed) objects.push(parsed);
    i = end + 1;
  }
  return { rest: '', objects };
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
    const bytes = Uint8Array.from(Buffer.from(value, 'base64'));
    return bytes.buffer;
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

/** Turns a finished English phrase into speech, streaming audio as soon as the first chunk exists. */
export async function speakEnglishStream(
  text: string,
  emotion: GooseEmotion = 'neutral',
  signal: AbortSignal | undefined,
  onChunk: (chunk: { samples: Float32Array; sampleRate: number; alignment?: SpeechAlignment }) => void,
): Promise<void> {
  if (!voiceConfig.voiceConfigured) throw new VoiceError(voiceConfig.setupMessage);
  const spoken = prepareSpeechText(text);
  const request = buildStreamSpeechRequest(spoken, voiceConfig.voiceId, voiceConfig.apiKey, emotion);
  let response: Response;
  try {
    response = await fetch(request.url, { method: 'POST', headers: request.headers, body: request.body, signal });
  } catch (error) {
    if (signal?.aborted) throw error;
    throw new VoiceError(messageForSpeechError());
  }
  if (!response.ok) throw new VoiceError(messageForSpeechError(response.status, await readErrorDetail(response)));

  let alignment: SpeechAlignment | undefined;
  let samplesSoFar = 0;
  let heardAudio = false;

  await forEachStreamObject(response, signal, body => {
    if (!body.audio_base64) return;
    const samples = pcm16ToFloat(bytesFromBase64(body.audio_base64));
    if (!samples.length) return;
    heardAudio = true;
    const timeOffset = samplesSoFar / ELEVENLABS_STREAM_SAMPLE_RATE;
    samplesSoFar += samples.length;
    alignment = mergeAlignment(alignment, alignmentFromBody(body), timeOffset);
    onChunk({ samples, sampleRate: ELEVENLABS_STREAM_SAMPLE_RATE, alignment });
  });

  if (!heardAudio) throw new VoiceError('Mr. Goose could not speak that line.');
}

async function forEachStreamObject(response: Response, signal: AbortSignal | undefined, onObject: (body: StreamSpeechChunk) => void): Promise<void> {
  const emit = (text: string, rest = '') => {
    const consumed = consumeStreamObjects(rest + text);
    for (const object of consumed.objects) onObject(object);
    return consumed.rest;
  };

  if (response.body && typeof response.body.getReader === 'function') {
    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let buffer = '';
    while (true) {
      if (signal?.aborted) {
        await reader.cancel();
        throw new VoiceError('Stopped.');
      }
      const { done, value } = await reader.read();
      buffer = emit(decoder.decode(value ?? new Uint8Array(), { stream: !done }), buffer);
      if (done) break;
    }
    emit('', buffer);
    return;
  }

  emit(await response.text());
}

/** Turns English text into an MP3 buffer plus word timings. Used if the stream path cannot run. */
export async function speakEnglish(text: string, signal?: AbortSignal, emotion: GooseEmotion = 'neutral'): Promise<SpokenClip> {
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
