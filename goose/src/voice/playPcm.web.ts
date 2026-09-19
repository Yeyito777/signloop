export type PcmPlayback = {
  push: (samples: Float32Array) => void;
  end: () => Promise<void>;
  stop: () => void;
  currentTime: () => number;
};

export function createPcmPlayback(sampleRate: number, onEnded: () => void): PcmPlayback {
  const context = new AudioContext({ sampleRate });
  void context.resume();
  const sources: AudioBufferSourceNode[] = [];
  let nextTime = 0;
  let origin: number | null = null;
  let stopped = false;
  let finished = false;
  let expectMore = true;

  const finish = () => {
    if (finished || stopped) return;
    finished = true;
    onEnded();
  };

  return {
    push(samples) {
      if (stopped || finished || samples.length === 0) return;
      try {
        const buffer = context.createBuffer(1, samples.length, sampleRate);
        buffer.getChannelData(0).set(samples);
        const src = context.createBufferSource();
        src.buffer = buffer;
        src.connect(context.destination);
        if (origin === null) {
          origin = context.currentTime;
          nextTime = origin;
        }
        const when = Math.max(context.currentTime, nextTime);
        src.start(when);
        nextTime = when + buffer.duration;
        sources.push(src);
        src.onended = () => {
          if (!expectMore && src === sources[sources.length - 1]) finish();
        };
      } catch {
        /* Keep going; the mpeg fallback can still play the line. */
      }
    },
    async end() {
      expectMore = false;
      if (stopped || finished) return;
      if (!sources.length) {
        finish();
        return;
      }
      if (context.currentTime >= nextTime - 0.02) {
        finish();
        return;
      }
      sources[sources.length - 1]!.onended = finish;
    },
    stop() {
      stopped = true;
      for (const src of sources) {
        src.onended = null;
        try { src.stop(); } catch { /* already finished */ }
      }
      void context.close();
    },
    currentTime: () => {
      if (origin === null) return 0;
      return Math.max(0, context.currentTime - origin);
    },
  };
}
