import { File as CacheFile, Paths } from 'expo-file-system';
import { useCallback, useEffect, useRef, useState } from 'react';
import { Platform } from 'react-native';
import type { GooseEmotion } from '../components/goose/motion.ts';
import { voiceConfig } from '../voice/config.ts';
import { envelopeFromMpeg, envelopeFromPcm, type LipSync } from '../voice/envelope.ts';
import {
  ELEVENLABS_STREAM_SAMPLE_RATE,
  speakEnglish,
  speakEnglishStream,
  VoiceError,
} from '../voice/elevenlabs.ts';
import { cuesFromText, cuesFromWords, wordsFromAlignment, type SpeechAlignment } from '../voice/gestures.ts';
import { concatFloat32 } from '../voice/pcm.ts';
import { englishWhenReady, type GoosePhrase } from '../voice/phrase.ts';
import { playClip, unlockPlayback } from '../voice/playClip.ts';
import { createPcmPlayback } from '../voice/playPcm.ts';

export type VoiceStatus = 'idle' | 'waiting' | 'loading' | 'speaking' | 'error';

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

function gesturesFor(spoken: string, alignment?: SpeechAlignment) {
  return alignment
    ? cuesFromWords(wordsFromAlignment(alignment))
    : cuesFromText(spoken);
}

export function useGooseVoice() {
  const [status, setStatus] = useState<VoiceStatus>('idle');
  const [error, setError] = useState<string | null>(null);
  const [pending, setPending] = useState<string | null>(null);
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
    setPending(null);
    setStatus('idle');
  }, [releaseClip]);

  const playMpeg = useCallback(async (spoken: string, emotion: GooseEmotion, id: number, signal: AbortSignal) => {
    const clipAudio = await speakEnglish(spoken, signal, emotion);
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
    lipSync.current = {
      envelope,
      gestures: gesturesFor(spoken, clipAudio.alignment),
      currentTime: playback.currentTime,
    };
    stopPlayback.current = playback.stop;
    setLastSpoken(spoken);
    setPending(null);
    setStatus('speaking');
  }, []);

  const receive = useCallback(async (phrase: GoosePhrase) => {
    let readyEnglish: string | null;
    try {
      readyEnglish = englishWhenReady(phrase);
    } catch (caught) {
      setError(caught instanceof VoiceError ? caught.message : 'Type something for Mr. Goose to say.');
      setStatus('error');
      return;
    }

    if (readyEnglish === null) {
      requestId.current += 1;
      abortRef.current?.abort();
      abortRef.current = null;
      lipSync.current = { currentTime: () => 0 };
      releaseClip();
      const draft = phrase.text.trim();
      setError(null);
      setPending(draft || null);
      setStatus(draft ? 'waiting' : 'idle');
      return;
    }

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
    setPending(readyEnglish);
    setStatus('loading');

    if (voiceConfig.backendConfigured) {
      try {
        await playMpeg(readyEnglish, phrase.emotion, id, abort.signal);
      } catch (caught) {
        if (id !== requestId.current || abort.signal.aborted) return;
        setError(caught instanceof VoiceError ? caught.message : 'Mr. Goose could not speak that line.');
        setStatus('error');
      }
      return;
    }

    const playback = createPcmPlayback(ELEVENLABS_STREAM_SAMPLE_RATE, () => {
      if (id === requestId.current) {
        lipSync.current = { currentTime: () => 0 };
        setStatus('idle');
      }
    });
    stopPlayback.current = playback.stop;
    const parts: Float32Array[] = [];
    let started = false;

    try {
      await speakEnglishStream(readyEnglish, phrase.emotion, abort.signal, chunk => {
        if (id !== requestId.current) return;
        parts.push(chunk.samples);
        playback.push(chunk.samples);
        lipSync.current = {
          envelope: envelopeFromPcm(concatFloat32(parts), ELEVENLABS_STREAM_SAMPLE_RATE),
          gestures: gesturesFor(readyEnglish, chunk.alignment),
          currentTime: playback.currentTime,
        };
        if (!started && Platform.OS === 'web') {
          started = true;
          setLastSpoken(readyEnglish);
          setPending(null);
          setStatus('speaking');
        }
      });
      if (id !== requestId.current) {
        playback.stop();
        return;
      }
      await playback.end();
      if (id !== requestId.current) return;
      if (!started) {
        if (!parts.length) {
          playback.stop();
          await playMpeg(readyEnglish, phrase.emotion, id, abort.signal);
          return;
        }
        setLastSpoken(readyEnglish);
        setPending(null);
        setStatus('speaking');
      }
    } catch (caught) {
      playback.stop();
      if (id !== requestId.current || abort.signal.aborted) return;
      try {
        await playMpeg(readyEnglish, phrase.emotion, id, abort.signal);
      } catch (fallback) {
        if (id !== requestId.current || abort.signal.aborted) return;
        const reason = fallback instanceof VoiceError ? fallback
          : caught instanceof VoiceError ? caught
          : undefined;
        setError(reason?.message ?? 'Mr. Goose could not speak that line.');
        setStatus('error');
      }
    }
  }, [playMpeg, releaseClip]);

  const speak = useCallback((text: string, emotion: GooseEmotion = 'neutral') => {
    return receive({ text, emotion, ready: true });
  }, [receive]);

  useEffect(() => () => {
    requestId.current += 1;
    abortRef.current?.abort();
    releaseClip();
  }, [releaseClip]);

  return {
    status,
    error,
    pending,
    lastSpoken,
    configured: voiceConfig.voiceConfigured,
    setupMessage: voiceConfig.setupMessage,
    lipSync,
    receive,
    speak,
    stop,
  };
}
