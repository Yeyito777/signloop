import { voiceConfig } from './config.ts';

export const ELEVENLABS_MODEL_ID = 'eleven_turbo_v2_5';
export const ELEVENLABS_OUTPUT_FORMAT = 'mp3_44100_128';

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

export function buildSpeechRequest(text: string, voiceId: string, apiKey: string) {
  return {
    url: `https://api.elevenlabs.io/v1/text-to-speech/${encodeURIComponent(voiceId)}?output_format=${ELEVENLABS_OUTPUT_FORMAT}`,
    headers: {
      'xi-api-key': apiKey,
      'Content-Type': 'application/json',
      Accept: 'audio/mpeg',
    },
    body: JSON.stringify({ text, model_id: ELEVENLABS_MODEL_ID }),
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
export async function speakEnglish(text: string, signal?: AbortSignal): Promise<ArrayBuffer> {
  if (!voiceConfig.voiceConfigured) throw new VoiceError(voiceConfig.setupMessage);
  const request = buildSpeechRequest(prepareSpeechText(text), voiceConfig.voiceId, voiceConfig.apiKey);
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
