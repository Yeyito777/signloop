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
};
