// The palette and idle motion live here so Mr. Goose is easy to art-direct.
export const colors = {
  background: '#F6F1E7',
  face: '#626975',
  neck: '#24272B',
  body: '#8B7560',
  wings: '#665444',
  belly: '#D6C8AE',
  cheeks: '#FFFCF0',
  beakAndFeet: '#303236',
  eyes: '#11151B',
  highlight: '#FFFFFF',
  shadow: '#76654E',
  steam: '#D9D1C3',
  tear: '#5AA8D4',
};

export const motion = {
  breathingAmount: 0.018,
  breathingSeconds: 4.8,
  bobAmount: 0.014,
  bobSeconds: 6.5,
  headTiltRadians: 0.045,
  headTiltSeconds: 9,
  wingRadians: 0.035,
  wingSeconds: 7,
  blinkSeconds: 0.19,
  // Uneven gaps feel less mechanical. The sequence repeats after 25 seconds.
  blinkAtSeconds: [3.2, 8.7, 12.9, 19.1, 19.48, 23.7],
  blinkCycleSeconds: 25,
  blendSeconds: 0.3,
  watchingPitch: 0.05,
  watchingTilt: 0.02,
  watchingEyes: 0.06,
  thinkingYaw: 0.07,
  thinkingYawSeconds: 5.4,
  thinkingBreath: -0.005,
  speakingBeak: 0.42,
  speakingBeakSeconds: 0.24,
  speakingBob: 0.006,
  speakingBreath: 0.007,
  fearJump: 0.09,
  fearJumpSeconds: 1.2,
};

export const poseLimits = {
  breath: 0.06,
  bob: 0.14,
  tilt: 0.16,
  wing: 0.12,
  yaw: 0.2,
  pitch: 0.2,
  beak: 1,
  eyesMin: 0.039,
};

export const emotionOffset = {
  joy: { bob: 0.022, pitch: -0.12, tilt: 0.05 },
  sadness: { pitch: 0.16, eyes: -0.38, breath: -0.012, bob: -0.012 },
  anger: { pitch: 0.1, eyes: -0.42, wing: 0.055, tilt: -0.06 },
  fear: { eyes: 0.08, pitch: -0.1, yaw: 0.1 },
} as const;
