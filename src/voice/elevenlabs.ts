import type { GooseEmotion } from '../components/goose/motion.ts';
import { voiceConfig } from './config.ts';

export const ELEVENLABS_MODEL_ID = 'eleven_multilingual_v2';
export const ELEVENLABS_OUTPUT_FORMAT = 'mp3_44100_128';
export const ELEVENLABS_VOICE_SETTINGS = {
  stability: 0.85,
  similarity_boost: 0.9,
  style: 0,
  speed: 1,
  use_speaker_boost: true,
};

export const emotionVoice = {
  joy: { stability: 0.32, similarity_boost: 0.72, style: 0.62, speed: 1.12, use_speaker_boost: true },
  sadness: { stability: 0.58, similarity_boost: 0.86, style: 0.4, speed: 0.82, use_speaker_boost: true },
  anger: { stability: 0.28, similarity_boost: 0.7, style: 0.7, speed: 1.06, use_speaker_boost: true },
  fear: { stability: 0.3, similarity_boost: 0.68, style: 0.55, speed: 1.14, use_speaker_boost: true },
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

export function buildSpeechRequest(text: string, voiceId: string, apiKey: string, emotion: GooseEmotion = 'joy') {
  return {
    url: `https://api.elevenlabs.io/v1/text-to-speech/${encodeURIComponent(voiceId)}?output_format=${ELEVENLABS_OUTPUT_FORMAT}`,
    headers: {
      'xi-api-key': apiKey,
      'Content-Type': 'application/json',
      Accept: 'audio/mpeg',
    },
    body: JSON.stringify({
      text,
      model_id: ELEVENLABS_MODEL_ID,
      seed: seedForSpeechText(text, emotion),
      voice_settings: emotionVoice[emotion],
    }),
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

/** Turns English text into an MP3 buffer. Future ASR can call this unchanged. */
export async function speakEnglish(text: string, signal?: AbortSignal, emotion: GooseEmotion = 'joy'): Promise<ArrayBuffer> {
  if (!voiceConfig.voiceConfigured) throw new VoiceError(voiceConfig.setupMessage);
  const request = buildSpeechRequest(prepareSpeechText(text), voiceConfig.voiceId, voiceConfig.apiKey, emotion);
  let response: Response;
  try {
    response = await fetch(request.url, { method: 'POST', headers: request.headers, body: request.body, signal });
  } catch (error) {
    if (signal?.aborted) throw error;
    throw new VoiceError(messageForSpeechError());
  }
  if (!response.ok) throw new VoiceError(messageForSpeechError(response.status, await readErrorDetail(response)));
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
