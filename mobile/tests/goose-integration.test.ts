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

test('the goose keeps its height as larger text claims more caption space', () => {
  for (const availableHeight of [660, 800]) {
    const normal = conversationLayout(availableHeight, 1);
    const large = conversationLayout(availableHeight, 1.3);
    assert.equal(large.goose, normal.goose);
    assert.ok(large.caption >= normal.caption);
      assert.ok(Math.abs(large.camera + large.goose + large.caption + large.clearance - availableHeight) < 1e-6);
  }
});

test('speaking shrinks the camera preview while captions stay compact', () => {
  assert.equal(conversationFocus('idle'), 'listening');
  assert.equal(conversationFocus('speaking', true), 'listening');
  assert.equal(conversationFocus('thinking', true), 'listening');
  assert.equal(conversationFocus('speaking'), 'speaking');
  for (const availableHeight of [400, 520, 660, 800]) {
    const listening = conversationLayout(availableHeight, 1, 'listening');
    const thinking = conversationLayout(availableHeight, 1, 'thinking');
    const speaking = conversationLayout(availableHeight, 1, 'speaking');
    assert.equal(thinking.goose, listening.goose);
    assert.equal(speaking.caption, listening.caption);
    assert.ok(listening.caption <= availableHeight * 0.28 + 1e-6);
    assert.ok(speaking.goose >= listening.goose);
    assert.ok(speaking.camera < listening.camera);
    assert.ok(speaking.camera >= 72 - 1e-6);
    for (const row of [listening, thinking, speaking]) {
      assert.ok(Math.abs(row.camera + row.goose + row.caption + row.clearance - availableHeight) < 1e-6);
    }
  }
});
