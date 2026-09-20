import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  activityOffset,
  advanceTime,
  composePose,
  gestureOffset,
  gooseActivities,
  gooseEmotions,
  gooseGestures,
  idlePose,
  stepPose,
} from '../../goose/src/components/goose/motion.ts';
import { motion, poseLimits } from '../../goose/src/components/goose/settings.ts';

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
  assert.deepEqual(idlePose(0), {
    breath: 1, bob: 0, tilt: 0, wing: 0, leftWing: 0, rightWing: 0,
    leftWingYaw: 0, rightWingYaw: 0, leftWingPitch: 0, rightWingPitch: 0,
    eyes: 1, yaw: 0, bodyYaw: 0, pitch: 0, beak: 0,
  });
  for (let t = 0; t < 100; t += 0.01) {
    const p = idlePose(t);
    assert.ok(Math.abs(p.breath - 1) <= motion.breathingAmount + 1e-9);
    assert.ok(Math.abs(p.bob) <= motion.bobAmount);
    assert.ok(Math.abs(p.tilt) <= motion.headTiltRadians);
    assert.ok(Math.abs(p.wing) <= motion.wingRadians);
    assert.ok(p.eyes >= 0.039 && p.eyes <= 1);
    assert.equal(p.yaw, 0);
    assert.equal(p.pitch, 0);
    assert.equal(p.beak, 0);
    assert.equal(p.leftWing, 0);
    assert.equal(p.rightWing, 0);
    assert.equal(p.bodyYaw, 0);
  }
});

test('Idle activity matches the idle clock', () => {
  for (const t of [0, 1.2, 8.7, 19.2]) {
    assert.deepEqual(composePose(t, 'idle'), idlePose(t));
  }
});

test('Speaking opens the beak; Idle does not', () => {
  assert.equal(activityOffset('idle', 0.2).beak, 0);
  assert.equal(composePose(0.2, 'idle').beak, 0);
  const peak = motion.speakingBeakSeconds * 0.25;
  assert.ok(composePose(peak, 'speaking').beak > 0.2);
});

test('lip-sync loudness opens the beak more than silence', () => {
  assert.ok(composePose(0, 'speaking', undefined, 1).beak > composePose(0, 'speaking', undefined, 0).beak + 0.2);
  assert.ok(composePose(0, 'speaking', undefined, 0).beak < 0.1);
});

test('Watching and Thinking change the pose versus Idle', () => {
  assert.ok(composePose(0, 'watching').pitch < composePose(0, 'idle').pitch);
  assert.notEqual(composePose(1.3, 'thinking').yaw, composePose(1.3, 'idle').yaw);
});

test('Fear hops higher than Idle', () => {
  let maxFear = 0;
  let maxIdle = 0;
  for (let t = 0; t < motion.fearJumpSeconds; t += 0.02) {
    maxFear = Math.max(maxFear, composePose(t, 'idle', 'fear').bob);
    maxIdle = Math.max(maxIdle, composePose(t, 'idle').bob);
  }
  assert.ok(maxFear > maxIdle + 0.03);
});

test('hello and you lift a wing; back turns the head', () => {
  assert.ok((gestureOffset('hello', 0.5).rightWing ?? 0) > 0.2);
  assert.ok((gestureOffset('you', 0.5).rightWingPitch ?? 0) > 0.4);
  assert.ok((gestureOffset('me', 0.5).rightWingYaw ?? 0) > 0.4);
  assert.ok((gestureOffset('there', 0.5).bodyYaw ?? 0) > 0.2);
  assert.ok((gestureOffset('back', 0.5).bodyYaw ?? 0) < -0.2);
  assert.notDeepEqual(gestureOffset('hello', 0.5), gestureOffset('you', 0.5));
  assert.notDeepEqual(gestureOffset('you', 0.5), gestureOffset('me', 0.5));
  assert.notDeepEqual(gestureOffset('me', 0.5), gestureOffset('there', 0.5));
  assert.notDeepEqual(gestureOffset('there', 0.5), gestureOffset('back', 0.5));
  for (const name of gooseGestures) {
    const p = composePose(0, 'idle', undefined, undefined, { name, localTime: 0.5 });
    assert.ok(Math.abs(p.rightWing) <= poseLimits.wing + 1e-9);
    assert.ok(Math.abs(p.bodyYaw) <= poseLimits.bodyYaw + 1e-9);
    assert.ok(Math.abs(p.rightWingPitch) <= poseLimits.wingTwist + 1e-9);
    assert.ok(Math.abs(p.rightWingYaw) <= poseLimits.wingTwist + 1e-9);
  }
});

test('expressive emotions change the pose while neutral preserves Idle', () => {
  for (const emotion of gooseEmotions) {
    if (emotion === 'neutral') assert.deepEqual(composePose(1.2, 'idle', emotion), composePose(1.2, 'idle'));
    else assert.notDeepEqual(composePose(1.2, 'idle', emotion), composePose(1.2, 'idle'));
  }
});

test('composed poses stay inside the small motion limits', () => {
  for (const activity of gooseActivities) {
    for (const emotion of [undefined, ...gooseEmotions]) {
      for (let t = 0; t < 20; t += 0.1) {
        const p = composePose(t, activity, emotion);
        assert.ok(Math.abs(p.breath - 1) <= poseLimits.breath + 1e-9);
        assert.ok(Math.abs(p.bob) <= poseLimits.bob + 1e-9);
        assert.ok(Math.abs(p.tilt) <= poseLimits.tilt + 1e-9);
        assert.ok(Math.abs(p.wing) <= poseLimits.wing + 1e-9);
        assert.ok(Math.abs(p.leftWing) <= poseLimits.wing + 1e-9);
        assert.ok(Math.abs(p.rightWing) <= poseLimits.wing + 1e-9);
        assert.ok(Math.abs(p.leftWingYaw) <= poseLimits.wingTwist + 1e-9);
        assert.ok(Math.abs(p.rightWingYaw) <= poseLimits.wingTwist + 1e-9);
        assert.ok(Math.abs(p.leftWingPitch) <= poseLimits.wingTwist + 1e-9);
        assert.ok(Math.abs(p.rightWingPitch) <= poseLimits.wingTwist + 1e-9);
        assert.ok(Math.abs(p.yaw) <= poseLimits.yaw + 1e-9);
        assert.ok(Math.abs(p.bodyYaw) <= poseLimits.bodyYaw + 1e-9);
        assert.ok(Math.abs(p.pitch) <= poseLimits.pitch + 1e-9);
        assert.ok(p.beak >= 0 && p.beak <= poseLimits.beak);
        assert.ok(p.eyes >= poseLimits.eyesMin && p.eyes <= 1);
      }
    }
  }
});

test('the same time, activity, and emotion stay deterministic', () => {
  assert.deepEqual(composePose(3.4, 'speaking', 'joy'), composePose(3.4, 'speaking', 'joy'));
  const start = idlePose(0);
  const toward = stepPose(start, composePose(1, 'watching', 'sadness'), 0.1);
  assert.notDeepEqual(toward, start);
});
