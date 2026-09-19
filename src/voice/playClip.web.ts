import { VoiceError } from './elevenlabs.ts';

const silentWav = 'data:audio/wav;base64,UklGRiQAAABXQVZFZm10IBAAAAABAAEAESsAACJWAAACABAAZGF0YQAAAAA=';

export function unlockPlayback() {
  const silent = new Audio(silentWav);
  silent.volume = 0;
  void silent.play().catch(() => { /* Gesture unlock; a later Speak will play the real clip. */ });
}

export async function playClip(uri: string, onEnded: () => void): Promise<{ stop: () => void }> {
  const audio = new Audio(uri);
  audio.preload = 'auto';
  const stop = () => {
    audio.onended = null;
    audio.onerror = null;
    audio.pause();
    audio.removeAttribute('src');
    audio.load();
  };
  audio.onended = onEnded;
  audio.onerror = onEnded;
  try {
    await audio.play();
  } catch {
    stop();
    throw new VoiceError('The browser blocked audio. Click Speak once more.');
  }
  return { stop };
}
