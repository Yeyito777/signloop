const apiKey = process.env.EXPO_PUBLIC_ELEVENLABS_API_KEY?.trim() ?? '';
const voiceId = process.env.EXPO_PUBLIC_ELEVENLABS_VOICE_ID?.trim() ?? '';

export const voiceConfig = {
  apiKey,
  voiceId,
  voiceConfigured: apiKey.length > 0 && voiceId.length > 0,
  setupMessage: 'Add your ElevenLabs API key and goose voice id to a local .env file, then restart Expo.',
};
