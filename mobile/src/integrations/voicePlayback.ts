import { createAudioPlayer, setAudioModeAsync } from 'expo-audio';
import { File, Paths } from 'expo-file-system';
import type { SpeechClip } from './speechTransport';
import { claimLipSync } from './lipSync';
import { cuesFromWords, wordsFromAlignment } from '../../../goose/src/voice/gestures';
import { assertNotAborted } from './abort';

let sequence = 0;
export async function playSpeechAudio(clip: SpeechClip, signal: AbortSignal, onStart?: () => void): Promise<void> {
  assertNotAborted(signal);
  await setAudioModeAsync({ playsInSilentMode: true, shouldPlayInBackground: false, interruptionMode: 'doNotMix' });
  assertNotAborted(signal);
  const file = new File(Paths.cache, `signloop-voice-${Date.now()}-${++sequence}.mp3`);
  let player: ReturnType<typeof createAudioPlayer> | undefined;
  let releaseLipSync = () => {};
  try {
    file.create({ overwrite: false });
    file.write(clip.audio);
    player = createAudioPlayer({ uri: file.uri }, { updateInterval: 50 });
    const audio = player;
    releaseLipSync = claimLipSync({
      currentTime: () => audio.currentTime,
      gestures: clip.alignment ? cuesFromWords(wordsFromAlignment(clip.alignment)) : undefined,
    });
    await new Promise<void>((resolve, reject) => {
      let began = false;
      let settled = false;
      let started = false;
      let timer: ReturnType<typeof setTimeout> | undefined;
      let startTimer: ReturnType<typeof setTimeout> | undefined;
      const cleanup = () => {
        if (timer) clearTimeout(timer);
        if (startTimer) clearTimeout(startTimer);
        subscription.remove();
        signal.removeEventListener('abort', abort);
      };
      const finish = (error?: Error) => {
        if (settled) return;
        settled = true;
        cleanup();
        error ? reject(error) : resolve();
      };
      const abort = () => finish(new Error('Playback cancelled.'));
      const tryPlay = () => {
        if (started || settled) return;
        started = true;
        try { audio.play(); } catch { finish(new Error('Audio playback failed.')); }
      };
      const subscription = audio.addListener('playbackStatusUpdate', status => {
        if (status.playbackState === 'error' || status.playbackState === 'failed') finish(new Error('Audio playback failed.'));
        else if (status.didJustFinish) finish();
        else if (status.playing && !began) { began = true; onStart?.(); }
        else if (status.isLoaded) tryPlay();
      });
      timer = setTimeout(() => finish(new Error('Audio playback timed out.')), 90_000);
      startTimer = setTimeout(tryPlay, 100);
      signal.addEventListener('abort', abort, { once: true });
      if (signal.aborted) { abort(); return; }
      if (audio.isLoaded) tryPlay();
    });
  } finally {
    releaseLipSync();
    try { player?.pause(); } finally {
      try { player?.remove(); } finally { if (file.exists) file.delete(); }
    }
  }
}
