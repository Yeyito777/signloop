import { emotionOffset, motion, poseLimits } from './settings.ts';

export type GooseActivity = 'idle' | 'watching' | 'thinking' | 'speaking';
export type { Emotion as GooseEmotion } from '../../emotion.ts';
import { emotions, type Emotion as GooseEmotion } from '../../emotion.ts';
export type GooseGesture = 'hello' | 'back' | 'you' | 'me' | 'there';

export type GoosePose = {
  breath: number;
  bob: number;
  tilt: number;
  wing: number;
  leftWing: number;
  rightWing: number;
  leftWingYaw: number;
  rightWingYaw: number;
  leftWingPitch: number;
  rightWingPitch: number;
  eyes: number;
  yaw: number;
  bodyYaw: number;
  pitch: number;
  beak: number;
};

export const gooseActivities = ['idle', 'watching', 'thinking', 'speaking'] as const satisfies readonly GooseActivity[];
export const gooseEmotions = emotions;
export const gooseGestures = ['hello', 'back', 'you', 'me', 'there'] as const satisfies readonly GooseGesture[];

const emptyOffset: GoosePose = {
  breath: 0, bob: 0, tilt: 0, wing: 0, leftWing: 0, rightWing: 0,
  leftWingYaw: 0, rightWingYaw: 0, leftWingPitch: 0, rightWingPitch: 0,
  eyes: 0, yaw: 0, bodyYaw: 0, pitch: 0, beak: 0,
};

const wave = (time: number, period: number) => Math.sin((time / period) * Math.PI * 2);

function addPose(base: GoosePose, offset: Partial<GoosePose>): GoosePose {
  return {
    breath: base.breath + (offset.breath ?? 0),
    bob: base.bob + (offset.bob ?? 0),
    tilt: base.tilt + (offset.tilt ?? 0),
    wing: base.wing + (offset.wing ?? 0),
    leftWing: base.leftWing + (offset.leftWing ?? 0),
    rightWing: base.rightWing + (offset.rightWing ?? 0),
    leftWingYaw: base.leftWingYaw + (offset.leftWingYaw ?? 0),
    rightWingYaw: base.rightWingYaw + (offset.rightWingYaw ?? 0),
    leftWingPitch: base.leftWingPitch + (offset.leftWingPitch ?? 0),
    rightWingPitch: base.rightWingPitch + (offset.rightWingPitch ?? 0),
    eyes: base.eyes + (offset.eyes ?? 0),
    yaw: base.yaw + (offset.yaw ?? 0),
    bodyYaw: base.bodyYaw + (offset.bodyYaw ?? 0),
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
    leftWing: Math.min(poseLimits.wing, Math.max(-poseLimits.wing, pose.leftWing)),
    rightWing: Math.min(poseLimits.wing, Math.max(-poseLimits.wing, pose.rightWing)),
    leftWingYaw: Math.min(poseLimits.wingTwist, Math.max(-poseLimits.wingTwist, pose.leftWingYaw)),
    rightWingYaw: Math.min(poseLimits.wingTwist, Math.max(-poseLimits.wingTwist, pose.rightWingYaw)),
    leftWingPitch: Math.min(poseLimits.wingTwist, Math.max(-poseLimits.wingTwist, pose.leftWingPitch)),
    rightWingPitch: Math.min(poseLimits.wingTwist, Math.max(-poseLimits.wingTwist, pose.rightWingPitch)),
    eyes: Math.min(1, Math.max(poseLimits.eyesMin, pose.eyes)),
    yaw: Math.min(poseLimits.yaw, Math.max(-poseLimits.yaw, pose.yaw)),
    bodyYaw: Math.min(poseLimits.bodyYaw, Math.max(-poseLimits.bodyYaw, pose.bodyYaw)),
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
    leftWing: 0,
    rightWing: 0,
    leftWingYaw: 0,
    rightWingYaw: 0,
    leftWingPitch: 0,
    rightWingPitch: 0,
    eyes,
    yaw: 0,
    bodyYaw: 0,
    pitch: 0,
    beak: 0,
  };
}

export function activityOffset(activity: GooseActivity, time: number, speakingLevel?: number): GoosePose {
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
    const open = speakingLevel === undefined
      ? 0.55 + 0.45 * wave(time, motion.speakingBeakSeconds)
      : 0.08 + 0.92 * Math.min(1, Math.max(0, speakingLevel));
    return {
      ...emptyOffset,
      beak: motion.speakingBeak * open,
      bob: motion.speakingBob * (speakingLevel === undefined ? wave(time, motion.speakingBeakSeconds) : open),
      breath: motion.speakingBreath * (speakingLevel === undefined ? wave(time, motion.breathingSeconds) : open),
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
  if (!emotion || emotion === 'neutral') return {};
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

export function gestureOffset(name: GooseGesture, localTime: number): Partial<GoosePose> {
  const t = Math.min(1, Math.max(0, localTime));
  const rise = Math.sin(t * Math.PI);
  if (name === 'hello') {
    const flap = 0.5 + 0.5 * Math.sin(t * Math.PI * 6);
    return { rightWing: 0.25 * rise + 0.85 * rise * flap, tilt: 0.1 * rise };
  }
  if (name === 'me') {
    return { rightWing: 0.35 * rise, rightWingYaw: 0.85 * rise, pitch: 0.16 * rise, yaw: 0.1 * rise };
  }
  if (name === 'you') {
    return { rightWing: 0.4 * rise, rightWingPitch: 0.95 * rise, pitch: -0.12 * rise };
  }
  if (name === 'there') {
    return { rightWing: 0.95 * rise, bodyYaw: 0.42 * rise, yaw: 0.2 * rise };
  }
  return { bodyYaw: -0.5 * rise, yaw: -0.22 * rise, leftWing: 0.2 * rise };
}

export function composePose(
  time: number,
  activity: GooseActivity,
  emotion?: GooseEmotion,
  speakingLevel?: number,
  gesture?: { name: GooseGesture; localTime: number },
): GoosePose {
  const withEmotion = addPose(addPose(idlePose(time), activityOffset(activity, time, speakingLevel)), emotionTint(emotion, time));
  return clampPose(gesture ? addPose(withEmotion, gestureOffset(gesture.name, gesture.localTime)) : withEmotion);
}

export function mixPose(from: GoosePose, to: GoosePose, amount: number): GoosePose {
  const t = Math.min(1, Math.max(0, amount));
  return {
    breath: from.breath + (to.breath - from.breath) * t,
    bob: from.bob + (to.bob - from.bob) * t,
    tilt: from.tilt + (to.tilt - from.tilt) * t,
    wing: from.wing + (to.wing - from.wing) * t,
    leftWing: from.leftWing + (to.leftWing - from.leftWing) * t,
    rightWing: from.rightWing + (to.rightWing - from.rightWing) * t,
    leftWingYaw: from.leftWingYaw + (to.leftWingYaw - from.leftWingYaw) * t,
    rightWingYaw: from.rightWingYaw + (to.rightWingYaw - from.rightWingYaw) * t,
    leftWingPitch: from.leftWingPitch + (to.leftWingPitch - from.leftWingPitch) * t,
    rightWingPitch: from.rightWingPitch + (to.rightWingPitch - from.rightWingPitch) * t,
    eyes: from.eyes + (to.eyes - from.eyes) * t,
    yaw: from.yaw + (to.yaw - from.yaw) * t,
    bodyYaw: from.bodyYaw + (to.bodyYaw - from.bodyYaw) * t,
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
