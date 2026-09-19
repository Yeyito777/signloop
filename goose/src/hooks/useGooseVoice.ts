import { File as CacheFile, Paths } from 'expo-file-system';
import { useCallback, useEffect, useRef, useState } from 'react';
import { Platform } from 'react-native';
import type { GooseEmotion } from '../components/goose/motion.ts';
import { voiceConfig } from '../voice/config.ts';
import { envelopeFromMpeg, type LipSync } from '../voice/envelope.ts';
import { prepareSpeechText, speakEnglish, VoiceError } from '../voice/elevenlabs.ts';
import { cuesFromText, cuesFromWords, wordsFromAlignment } from '../voice/gestures.ts';
import { playClip, unlockPlayback } from '../voice/playClip.ts';

export type VoiceStatus = 'idle' | 'loading' | 'speaking' | 'error';

type CachedClip = { uri: string; release: () => void };

function cacheSpeechAudio(buffer: ArrayBuffer): CachedClip {
  if (Platform.OS === 'web') {
    const uri = URL.createObjectURL(new Blob([buffer], { type: 'audio/mpeg' }));
    return { uri, release: () => URL.revokeObjectURL(uri) };
  }
  const file = new CacheFile(Paths.cache, `goose-voice-${Date.now()}.mp3`);
  file.create({ overwrite: true });
  file.write(new Uint8Array(buffer));
  return { uri: file.uri, release: () => { if (file.exists) file.delete(); } };
}

export function useGooseVoice() {
  const [status, setStatus] = useState<VoiceStatus>('idle');
  const [error, setError] = useState<string | null>(null);
  const [lastSpoken, setLastSpoken] = useState<string | null>(null);
  const requestId = useRef(0);
  const stopPlayback = useRef<(() => void) | null>(null);
  const clipRef = useRef<CachedClip | null>(null);
  const abortRef = useRef<AbortController | null>(null);
  const lipSync = useRef<LipSync>({ currentTime: () => 0 });

  const releaseClip = useCallback(() => {
    stopPlayback.current?.();
    stopPlayback.current = null;
    clipRef.current?.release();
    clipRef.current = null;
  }, []);

  const stop = useCallback(() => {
    requestId.current += 1;
    abortRef.current?.abort();
    abortRef.current = null;
    lipSync.current = { currentTime: () => 0 };
    releaseClip();
    setStatus('idle');
  }, [releaseClip]);

  const speak = useCallback(async (text: string, emotion: GooseEmotion = 'joy') => {
    if (!voiceConfig.voiceConfigured) {
      setError(voiceConfig.setupMessage);
      setStatus('error');
      return;
    }

    unlockPlayback();
    const id = ++requestId.current;
    abortRef.current?.abort();
    const abort = new AbortController();
    abortRef.current = abort;
    lipSync.current = { currentTime: () => 0 };
    releaseClip();
    setError(null);
    setStatus('loading');

    try {
      const spoken = prepareSpeechText(text);
      const clipAudio = await speakEnglish(spoken, abort.signal, emotion);
      if (id !== requestId.current) return;
      const envelope = await envelopeFromMpeg(clipAudio.buffer);
      if (id !== requestId.current) return;
      const clip = cacheSpeechAudio(clipAudio.buffer);
      clipRef.current = clip;
      const playback = await playClip(clip.uri, () => {
        if (id === requestId.current) {
          lipSync.current = { currentTime: () => 0 };
          setStatus('idle');
        }
      });
      if (id !== requestId.current) {
        playback.stop();
        return;
      }
      const gestures = clipAudio.alignment
        ? cuesFromWords(wordsFromAlignment(clipAudio.alignment))
        : cuesFromText(spoken);
      lipSync.current = { envelope, gestures, currentTime: playback.currentTime };
      stopPlayback.current = playback.stop;
      setLastSpoken(spoken);
      setStatus('speaking');
    } catch (caught) {
      if (id !== requestId.current || abort.signal.aborted) return;
      setError(caught instanceof VoiceError ? caught.message : 'Mr. Goose could not speak that line.');
      setStatus('error');
    }
  }, [releaseClip]);

  useEffect(() => () => {
    requestId.current += 1;
    abortRef.current?.abort();
    releaseClip();
  }, [releaseClip]);

  return {
    status,
    error,
    lastSpoken,
    configured: voiceConfig.voiceConfigured,
    setupMessage: voiceConfig.setupMessage,
    lipSync,
    speak,
    stop,
  };
}
