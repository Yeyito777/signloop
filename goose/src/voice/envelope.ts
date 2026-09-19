import type { GestureCue } from './gestures.ts';

export type SpeechEnvelope = {
  hopSeconds: number;
  levels: number[];
};

export type LipSync = {
  envelope?: SpeechEnvelope;
  gestures?: GestureCue[];
  currentTime: () => number;
};

export function envelopeFromPcm(samples: Float32Array, sampleRate: number, hopSeconds = 1 / 60): SpeechEnvelope {
  const hop = Math.max(1, Math.floor(sampleRate * hopSeconds));
  const levels: number[] = [];
  let peak = 1e-6;
  for (let start = 0; start < samples.length; start += hop) {
    const end = Math.min(samples.length, start + hop);
    let sum = 0;
    for (let i = start; i < end; i += 1) sum += samples[i] * samples[i];
    const rms = Math.sqrt(sum / Math.max(1, end - start));
    levels.push(rms);
    if (rms > peak) peak = rms;
  }
  return {
    hopSeconds,
    levels: levels.map(rms => {
      const n = rms / peak;
      if (n < 0.05) return 0;
      return Math.min(1, n ** 0.5);
    }),
  };
}

export function levelAt(envelope: SpeechEnvelope | undefined, time: number): number | undefined {
  if (!envelope || envelope.levels.length === 0) return undefined;
  const t = time / envelope.hopSeconds;
  if (t < 0) return envelope.levels[0];
  if (t >= envelope.levels.length - 1) return 0;
  const i = Math.floor(t);
  const f = t - i;
  return envelope.levels[i] * (1 - f) + envelope.levels[i + 1] * f;
}

export async function envelopeFromMpeg(buffer: ArrayBuffer): Promise<SpeechEnvelope | undefined> {
  if (typeof AudioContext === 'undefined') return undefined;
  const context = new AudioContext();
  try {
    if (context.state === 'suspended') await context.resume();
    const audio = await context.decodeAudioData(buffer.slice(0));
    return envelopeFromPcm(audio.getChannelData(0), audio.sampleRate);
  } catch {
    return undefined;
  } finally {
    void context.close();
  }
}
