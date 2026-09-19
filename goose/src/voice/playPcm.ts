import { File as CacheFile, Paths } from 'expo-file-system';
import { concatFloat32, wavFromPcm } from './pcm.ts';
import { playClip, type ClipPlayback } from './playClip.ts';

export type PcmPlayback = {
  push: (samples: Float32Array) => void;
  end: () => Promise<void>;
  stop: () => void;
  currentTime: () => number;
};

export function createPcmPlayback(sampleRate: number, onEnded: () => void): PcmPlayback {
  const parts: Float32Array[] = [];
  let clip: ClipPlayback | null = null;
  let file: CacheFile | null = null;
  let stopped = false;

  return {
    push(samples) {
      if (!stopped && samples.length) parts.push(samples);
    },
    async end() {
      if (stopped) return;
      const samples = concatFloat32(parts);
      if (!samples.length) {
        onEnded();
        return;
      }
      const wav = wavFromPcm(samples, sampleRate);
      file = new CacheFile(Paths.cache, `goose-voice-${Date.now()}.wav`);
      file.create({ overwrite: true });
      file.write(new Uint8Array(wav));
      clip = await playClip(file.uri, onEnded);
    },
    stop() {
      stopped = true;
      clip?.stop();
      clip = null;
      if (file?.exists) file.delete();
      file = null;
    },
    currentTime: () => clip?.currentTime() ?? 0,
  };
}
