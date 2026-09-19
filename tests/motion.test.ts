import assert from 'node:assert/strict';
import { test } from 'node:test';
import { advanceTime, idlePose } from '../src/components/goose/motion.ts';
import { motion } from '../src/components/goose/settings.ts';

test('pause holds a pose and resume advances from the held time', () => {
  let time = advanceTime(2, 1 / 60, true);
  const beforePause = idlePose(time);
  time = advanceTime(time, 20, false);
  assert.deepEqual(idlePose(time), beforePause);
  const resumed = advanceTime(time, 1 / 60, true);
  assert.ok(resumed > time);
  assert.notDeepEqual(idlePose(resumed), beforePause);
});

test('a delayed frame cannot jump the idle animation after backgrounding', () => {
  assert.equal(advanceTime(4, 60, true), 4.05);
  assert.equal(advanceTime(4, -1, true), 4);
});

test('blink fully closes then reopens, including across the cycle boundary', () => {
  const start = motion.blinkAtSeconds[0];
  assert.equal(idlePose(start - 0.01).eyes, 1);
  assert.ok(idlePose(start + motion.blinkSeconds * 0.4).eyes < 0.05);
  assert.equal(idlePose(start + motion.blinkSeconds + 0.01).eyes, 1);
  assert.equal(idlePose(motion.blinkCycleSeconds).eyes, 1);
});

test('neutral pose has open eyes; all idle motion stays within small limits', () => {
  assert.deepEqual(idlePose(0), { breath: 1, bob: 0, tilt: 0, wing: 0, eyes: 1 });
  for (let t = 0; t < 100; t += 0.01) {
    const p = idlePose(t);
    assert.ok(Math.abs(p.breath - 1) <= motion.breathingAmount + 1e-9);
    assert.ok(Math.abs(p.bob) <= motion.bobAmount);
    assert.ok(Math.abs(p.tilt) <= motion.headTiltRadians);
    assert.ok(Math.abs(p.wing) <= motion.wingRadians);
    assert.ok(p.eyes >= 0.039 && p.eyes <= 1);
  }
});
