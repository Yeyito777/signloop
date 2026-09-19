import { motion } from './settings.ts';

const wave = (time: number, period: number) => Math.sin((time / period) * Math.PI * 2);

// A local clock (instead of wall time) lets pause/resume preserve the exact pose.
export function advanceTime(time: number, delta: number, enabled: boolean) {
  return enabled ? time + Math.max(0, Math.min(delta, 1 / 20)) : time;
}

export function idlePose(time: number) {
  const cycleTime = time % motion.blinkCycleSeconds;
  let eyes = 1;
  for (const start of motion.blinkAtSeconds) {
    const progress = (cycleTime - start) / motion.blinkSeconds;
    if (progress >= 0 && progress <= 1) {
      // Fast close, gentle reopen. The whole eye group includes the glints.
      const closure = progress < 0.4 ? progress / 0.4 : (1 - progress) / 0.6;
      eyes = 1 - 0.96 * Math.sin(closure * Math.PI / 2);
    }
  }
  return {
    breath: 1 + motion.breathingAmount * wave(time, motion.breathingSeconds),
    bob: motion.bobAmount * wave(time, motion.bobSeconds),
    tilt: motion.headTiltRadians * wave(time, motion.headTiltSeconds),
    wing: motion.wingRadians * wave(time, motion.wingSeconds),
    eyes,
  };
}
