import assert from 'node:assert/strict';
import { test } from 'node:test';
import { goosePresentation } from '../src/integrations/goosePresentation.ts';
import { conversationLayout } from '../src/session/conversationLayout.ts';

test('processing does not assign an emotion to the signer', () => {
  assert.deepEqual(goosePresentation('thinking', 'neutral'), { activity: 'thinking', emotion: undefined });
  assert.deepEqual(goosePresentation('listening', 'neutral'), { activity: 'watching', emotion: undefined });
  assert.deepEqual(goosePresentation('speaking', 'joy'), { activity: 'speaking', emotion: 'joy' });
  assert.deepEqual(goosePresentation('idle', 'fear'), { activity: 'idle', emotion: 'fear' });
});

test('the goose keeps its height as larger text claims more caption space', () => {
  for (const availableHeight of [400, 520, 660, 800]) {
    const normal = conversationLayout(availableHeight, 1);
    for (const fontScale of [1.3, 1.8, 2.4]) {
      const large = conversationLayout(availableHeight, fontScale);
      assert.equal(large.goose, normal.goose);
      assert.ok(large.caption >= normal.caption);
      assert.ok(large.camera >= availableHeight * 0.3 - 1e-6);
      assert.ok(Math.abs(large.camera + large.goose + large.caption - availableHeight) < 1e-6);
    }
  }
});
