import assert from 'node:assert/strict';
import { test } from 'node:test';
import { canPlayEmote, emptyEmotePlayer, emoteOffset, updateEmotePlayer, type EmoteRequest } from '../src/components/goose/emotes.ts';
import { composePose, gooseEmotions } from '../src/components/goose/motion.ts';
import { poseLimits } from '../src/components/goose/settings.ts';

const dance: EmoteRequest = { id: 'one', name: 'dance' };
const replay: EmoteRequest = { id: 'two', name: 'dance' };

test('one request plays once despite rerenders, cleanup/reconnect, and delayed frames', () => {
  const started = updateEmotePlayer(emptyEmotePlayer, dance, true, 100);
  const rerender = updateEmotePlayer(started.player, { ...dance }, true, 900);
  assert.equal(rerender.player.active?.startedAt, 100);
  assert.deepEqual(rerender.ended, []);
  const ended = updateEmotePlayer(rerender.player, dance, true, 9000);
  assert.equal(ended.player.active, null);
  assert.deepEqual(ended.ended, [{ id: dance.id, status: 'completed' }]);
  assert.deepEqual(updateEmotePlayer(ended.player, dance, true, 9500).ended, []);
  assert.equal(updateEmotePlayer(ended.player, dance, true, 9500).player.active, null);
});

test('Replay replaces the old action and gets its own full duration', () => {
  const started = updateEmotePlayer(emptyEmotePlayer, dance, true, 0);
  const replaced = updateEmotePlayer(started.player, replay, true, 2000);
  assert.deepEqual(replaced.ended, [{ id: dance.id, status: 'cancelled' }]);
  assert.equal(replaced.player.active?.request.id, replay.id);
  assert.equal(replaced.player.active?.startedAt, 2000);
  assert.ok(updateEmotePlayer(replaced.player, replay, true, 4999).player.active);
  assert.deepEqual(updateEmotePlayer(replaced.player, replay, true, 5000).ended, [{ id: replay.id, status: 'completed' }]);
});

test('Stop cancels once, and returning cannot replay the old request', () => {
  const started = updateEmotePlayer(emptyEmotePlayer, dance, true, 0);
  const stopped = updateEmotePlayer(started.player, null, true, 500);
  assert.deepEqual(stopped.ended, [{ id: dance.id, status: 'cancelled' }]);
  assert.deepEqual(updateEmotePlayer(stopped.player, null, true, 600).ended, []);
  assert.equal(updateEmotePlayer(stopped.player, dance, true, 700).player.active, null);
});

test('speech, pause and backgrounding cancel rather than queue an emote', () => {
  assert.equal(canPlayEmote(true, 'thinking'), false);
  assert.equal(canPlayEmote(true, 'speaking'), false);
  assert.equal(canPlayEmote(false, 'idle'), false);
  assert.equal(canPlayEmote(true, 'watching'), true);
  const started = updateEmotePlayer(emptyEmotePlayer, dance, true, 0);
  const blocked = updateEmotePlayer(started.player, dance, false, 500);
  assert.equal(blocked.player.active, null);
  assert.deepEqual(blocked.ended, [{ id: dance.id, status: 'cancelled' }]);
  assert.equal(updateEmotePlayer(blocked.player, dance, true, 1500).player.active, null);
});

test('reduced motion settles a new request without needing an animation frame', () => {
  const skipped = updateEmotePlayer(emptyEmotePlayer, dance, false, 0);
  assert.deepEqual(skipped.ended, [{ id: dance.id, status: 'skipped' }]);
  assert.equal(skipped.player.active, null);
  assert.deepEqual(updateEmotePlayer(skipped.player, dance, false, 100).ended, []);
  assert.equal(updateEmotePlayer(skipped.player, dance, true, 200).player.active, null);
});

test('dance fades in and out, alternates wings, and never opens the beak', () => {
  assert.deepEqual(emoteOffset('dance', 0), {});
  assert.deepEqual(emoteOffset('dance', 3000), {});
  assert.deepEqual(emoteOffset('dance', Infinity), {});
  const first = emoteOffset('dance', 875);
  const second = emoteOffset('dance', 1125);
  assert.ok(first.leftWing! > first.rightWing!);
  assert.ok(second.rightWing! > second.leftWing!);
  assert.equal(first.beak, undefined);
  for (const edge of [1, 2999]) {
    for (const offset of Object.values(emoteOffset('dance', edge))) assert.ok(Math.abs(offset!) < 0.001);
  }
});

test('all expressions stay within pose limits during the dance and return to their base pose', () => {
  for (const emotion of gooseEmotions) {
    for (const elapsedMS of [0, 3000, 4000]) {
      assert.deepEqual(composePose(4, 'watching', emotion, undefined, undefined, { name: 'dance', elapsedMS }), composePose(4, 'watching', emotion));
    }
    for (let elapsedMS = 0; elapsedMS <= 3000; elapsedMS += 10) {
      const pose = composePose(4, 'watching', emotion, undefined, undefined, { name: 'dance', elapsedMS });
      for (const key of ['bob', 'tilt', 'bodyYaw', 'pitch'] as const) assert.ok(Math.abs(pose[key]) <= poseLimits[key]);
      assert.ok(Math.abs(pose.leftWing) <= poseLimits.wing);
      assert.ok(Math.abs(pose.rightWing) <= poseLimits.wing);
      assert.equal(pose.beak, 0);
    }
  }
});

test('an emote cannot override speaking lip sync or word gestures, even with a stale prop', () => {
  const gesture = { name: 'hello' as const, localTime: 0.5 };
  const base = composePose(1, 'speaking', 'joy', 0.8, gesture);
  assert.deepEqual(composePose(1, 'speaking', 'joy', 0.8, gesture, { name: 'dance', elapsedMS: 1000 }), base);
  assert.deepEqual(composePose(1, 'thinking', 'joy', undefined, undefined, { name: 'dance', elapsedMS: 1000 }), composePose(1, 'thinking', 'joy'));
});
