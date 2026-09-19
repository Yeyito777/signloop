import test from 'node:test';
import assert from 'node:assert/strict';
import { framingFromCamera } from '../src/integrations/cameraStatus.ts';
import { initialSession, sessionReducer as reduce } from '../src/session/model.ts';

const observation = { captureId: 1, status: 'tracking' as const, handCount: 1, message: '' };

test('native camera callbacks cannot make a paused or newer session ready', () => {
  assert.equal(framingFromCamera(observation, false, 1), null);
  assert.equal(framingFromCamera(observation, true, 2), null);
  assert.equal(framingFromCamera(observation, true, 1), 'ready');
  assert.equal(framingFromCamera({ ...observation, handCount: 0 }, true, 1), 'hands-missing');
});

test('hand detection alone never creates a caption or voice request', () => {
  const state = reduce(initialSession(), { type: 'framing', framing: 'ready', captureId: 1 });
  assert.deepEqual(state.phrases, []);
  assert.equal(state.speech, null);
});

test('permission loss invalidates recognition and late tracking after pause is ignored', () => {
  const ready = reduce(initialSession(), { type: 'framing', framing: 'ready', captureId: 1 });
  const denied = reduce(ready, { type: 'framing', framing: 'camera-denied', captureId: 1 });
  assert.notEqual(denied.captureId, 1);
  assert.equal(reduce(denied, { type: 'translation', captureId: 1,
    event: { type: 'accepted', id: 'stale', text: 'Stale camera result', emotion: 'neutral' } }), denied);
  const paused = reduce(denied, { type: 'pause' });
  assert.equal(reduce(paused, { type: 'framing', framing: 'ready', captureId: paused.captureId }), paused);
});
