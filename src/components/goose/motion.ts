import { emotionOffset, motion, poseLimits } from './settings.ts';

export type GooseActivity = 'idle' | 'watching' | 'thinking' | 'speaking';
export type GooseEmotion = 'joy' | 'sadness' | 'anger' | 'fear';

export type GoosePose = {
  breath: number;
  bob: number;
  tilt: number;
  wing: number;
  eyes: number;
  yaw: number;
  pitch: number;
  beak: number;
};

export const gooseActivities = ['idle', 'watching', 'thinking', 'speaking'] as const satisfies readonly GooseActivity[];
export const gooseEmotions = ['joy', 'sadness', 'anger', 'fear'] as const satisfies readonly GooseEmotion[];

const emptyOffset: GoosePose = { breath: 0, bob: 0, tilt: 0, wing: 0, eyes: 0, yaw: 0, pitch: 0, beak: 0 };

const wave = (time: number, period: number) => Math.sin((time / period) * Math.PI * 2);

function addPose(base: GoosePose, offset: Partial<GoosePose>): GoosePose {
  return {
    breath: base.breath + (offset.breath ?? 0),
    bob: base.bob + (offset.bob ?? 0),
    tilt: base.tilt + (offset.tilt ?? 0),
    wing: base.wing + (offset.wing ?? 0),
    eyes: base.eyes + (offset.eyes ?? 0),
    yaw: base.yaw + (offset.yaw ?? 0),
    pitch: base.pitch + (offset.pitch ?? 0),
    beak: base.beak + (offset.beak ?? 0),
  };
}

function clampPose(pose: GoosePose): GoosePose {
  return {
    breath: Math.min(1 + poseLimits.breath, Math.max(1 - poseLimits.breath, pose.breath)),
    bob: Math.min(poseLimits.bob, Math.max(-poseLimits.bob, pose.bob)),
    tilt: Math.min(poseLimits.tilt, Math.max(-poseLimits.tilt, pose.tilt)),
    wing: Math.min(poseLimits.wing, Math.max(-poseLimits.wing, pose.wing)),
    eyes: Math.min(1, Math.max(poseLimits.eyesMin, pose.eyes)),
    yaw: Math.min(poseLimits.yaw, Math.max(-poseLimits.yaw, pose.yaw)),
    pitch: Math.min(poseLimits.pitch, Math.max(-poseLimits.pitch, pose.pitch)),
    beak: Math.min(poseLimits.beak, Math.max(0, pose.beak)),
  };
}

// A local clock (instead of wall time) lets pause/resume preserve the exact pose.
export function advanceTime(time: number, delta: number, enabled: boolean) {
  return enabled ? time + Math.max(0, Math.min(delta, 1 / 20)) : time;
}

export function idlePose(time: number): GoosePose {
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
    yaw: 0,
    pitch: 0,
    beak: 0,
  };
}

export function activityOffset(activity: GooseActivity, time: number): GoosePose {
  if (activity === 'watching') {
    return {
      ...emptyOffset,
      pitch: -motion.watchingPitch,
      tilt: motion.watchingTilt,
      eyes: motion.watchingEyes,
    };
  }
  if (activity === 'thinking') {
    return {
      ...emptyOffset,
      yaw: motion.thinkingYaw * wave(time, motion.thinkingYawSeconds),
      breath: motion.thinkingBreath,
    };
  }
  if (activity === 'speaking') {
    const open = 0.55 + 0.45 * wave(time, motion.speakingBeakSeconds);
    return {
      ...emptyOffset,
      beak: motion.speakingBeak * open,
      bob: motion.speakingBob * wave(time, motion.speakingBeakSeconds),
      breath: motion.speakingBreath * wave(time, motion.breathingSeconds),
    };
  }
  return emptyOffset;
}

function hop(time: number, period: number) {
  const cycle = (time % period) / period;
  if (cycle > 0.34) return 0;
  return Math.sin((cycle / 0.34) * Math.PI);
}

export function emotionTint(emotion: GooseEmotion | undefined, time: number): Partial<GoosePose> {
  if (!emotion) return {};
  if (emotion === 'fear') {
    const jump = hop(time, motion.fearJumpSeconds) * motion.fearJump;
    return {
      ...emotionOffset.fear,
      yaw: emotionOffset.fear.yaw * wave(time, 1.6),
      bob: jump,
      wing: jump * 0.35,
    };
  }
  return emotionOffset[emotion];
}

export function composePose(time: number, activity: GooseActivity, emotion?: GooseEmotion): GoosePose {
  return clampPose(addPose(addPose(idlePose(time), activityOffset(activity, time)), emotionTint(emotion, time)));
}

export function mixPose(from: GoosePose, to: GoosePose, amount: number): GoosePose {
  const t = Math.min(1, Math.max(0, amount));
  return {
    breath: from.breath + (to.breath - from.breath) * t,
    bob: from.bob + (to.bob - from.bob) * t,
    tilt: from.tilt + (to.tilt - from.tilt) * t,
    wing: from.wing + (to.wing - from.wing) * t,
    eyes: from.eyes + (to.eyes - from.eyes) * t,
    yaw: from.yaw + (to.yaw - from.yaw) * t,
    pitch: from.pitch + (to.pitch - from.pitch) * t,
    beak: from.beak + (to.beak - from.beak) * t,
  };
}

export function stepPose(current: GoosePose, target: GoosePose, delta: number, seconds = motion.blendSeconds): GoosePose {
  return mixPose(current, target, 1 - Math.exp(-Math.max(0, delta) / seconds));
}

export function stillPose(emotion?: GooseEmotion): GoosePose {
  return { ...composePose(0, 'idle', emotion), beak: 0 };
}
