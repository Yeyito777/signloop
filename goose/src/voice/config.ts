function loopbackOrigin(url: string): string {
  const trimmed = url.trim().replace(/\/$/, '');
  if (!trimmed) return '';
  try {
    const parsed = new URL(trimmed);
    if (parsed.username || parsed.password || parsed.pathname !== '/' || parsed.search || parsed.hash) return '';
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return '';
    if (parsed.hostname !== '127.0.0.1' && parsed.hostname !== 'localhost' && parsed.hostname !== '::1') return '';
    return trimmed;
  } catch {
    return '';
  }
}

const apiKey = process.env.EXPO_PUBLIC_ELEVENLABS_API_KEY?.trim() ?? '';
const voiceId = process.env.EXPO_PUBLIC_ELEVENLABS_VOICE_ID?.trim() ?? '';
const backendUrl = loopbackOrigin(process.env.EXPO_PUBLIC_VOICE_BACKEND_URL ?? '');
const backendToken = process.env.EXPO_PUBLIC_SIGNLOOP_BACKEND_TOKEN?.trim() ?? '';
const backendConfigured = backendUrl.length > 0 && backendToken.length >= 24;
const directConfigured = apiKey.length > 0 && voiceId.length > 0;

export const voiceConfig = {
  apiKey,
  voiceId,
  backendUrl,
  backendToken,
  backendConfigured,
  voiceConfigured: backendConfigured || directConfigured,
  setupMessage: 'Start the local voice backend and add EXPO_PUBLIC_VOICE_BACKEND_URL plus EXPO_PUBLIC_SIGNLOOP_BACKEND_TOKEN to goose/.env.',
};

export { loopbackOrigin };
