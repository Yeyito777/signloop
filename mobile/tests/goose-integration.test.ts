import assert from 'node:assert/strict';
import { test } from 'node:test';
import { goosePresentation } from '../src/integrations/goosePresentation.ts';
import { conversationFocus, conversationLayout } from '../src/session/conversationLayout.ts';

test('processing does not assign an emotion to the signer', () => {
  assert.deepEqual(goosePresentation('thinking', 'neutral'), { activity: 'thinking', emotion: undefined });
  assert.deepEqual(goosePresentation('listening', 'neutral'), { activity: 'watching', emotion: undefined });
  assert.deepEqual(goosePresentation('speaking', 'joy'), { activity: 'speaking', emotion: 'joy' });
  assert.deepEqual(goosePresentation('idle', 'fear'), { activity: 'idle', emotion: 'fear' });
});

test('larger captions take leftover space from the goose, not the landscape camera', () => {
  for (const availableHeight of [660, 800]) {
    const normal = conversationLayout(availableHeight, 1, 'listening', 390);
    const large = conversationLayout(availableHeight, 1.3, 'listening', 390);
    assert.equal(large.camera, normal.camera);
    assert.ok(large.caption >= normal.caption);
    assert.ok(large.goose <= normal.goose);
    assert.ok(Math.abs(large.camera + large.goose + large.caption + large.clearance - availableHeight) < 1e-6);
  }
});

test('the camera stays a landscape strip when the screen is wide enough', () => {
  const width = 390;
  for (const availableHeight of [520, 660, 800]) {
    const row = conversationLayout(availableHeight, 1, 'listening', width);
    assert.ok(row.camera <= width * 3 / 4 + 1e-6);
    assert.ok(row.camera < row.goose || row.camera <= width * 3 / 4 + 1e-6);
    assert.ok(Math.abs(row.camera + row.goose + row.caption + row.clearance - availableHeight) < 1e-6);
  }
});

test('speaking keeps captions compact and a landscape camera', () => {
  assert.equal(conversationFocus('idle'), 'listening');
  assert.equal(conversationFocus('speaking', true), 'listening');
  assert.equal(conversationFocus('thinking', true), 'listening');
  assert.equal(conversationFocus('speaking'), 'speaking');
  for (const availableHeight of [400, 520, 660, 800]) {
    const listening = conversationLayout(availableHeight, 1, 'listening', 390);
    const thinking = conversationLayout(availableHeight, 1, 'thinking', 390);
    const speaking = conversationLayout(availableHeight, 1, 'speaking', 390);
    assert.equal(thinking.goose, listening.goose);
    assert.equal(speaking.caption, listening.caption);
    assert.ok(listening.caption <= availableHeight * 0.22 + 1e-6);
    assert.equal(speaking.camera, listening.camera);
    for (const row of [listening, thinking, speaking]) {
      assert.ok(Math.abs(row.camera + row.goose + row.caption + row.clearance - availableHeight) < 1e-6);
    }
  }
});
