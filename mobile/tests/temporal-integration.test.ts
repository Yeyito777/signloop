import test from 'node:test';
import assert from 'node:assert/strict';
import { candidateFromSign, presentationSigns } from '../src/integrations/localSign.ts';
import { initialSession, sessionReducer as reduce } from '../src/session/model.ts';

test('all 11 native temporal labels reach candidates, never captions or speech without confirmation', () => {
  assert.equal(Object.keys(presentationSigns).length, 11);
  for (const label of Object.keys(presentationSigns)) {
    const now = Date.now();
    const event = candidateFromSign({ captureId: 1, label, observedAtMS: now }, true, 1)!;
    let s = reduce({ ...initialSession(), muted: true }, { type: 'framing', framing: 'ready', captureId: 1 });
    s = reduce(s, { type: 'translation', captureId: 1, event });
    assert.equal(s.candidate?.label, label);
    assert.equal(s.speech, null);
    assert.equal(s.phrases.length, 0);
    s = reduce(s, { type: 'confirm-candidate' });
    assert.equal(s.phrases[0].text, presentationSigns[label]);
    assert.equal(s.speech, null);
  }
});

test('mode change invalidates old detector epoch and spelling stays explicit and restricted', () => {
  let s = reduce(initialSession(), { type: 'recognition-mode', mode: 'spelling' });
  assert.equal(s.captureId, 2);
  s = reduce(s, { type: 'translation', captureId: 1, event: { type: 'candidate', label: 'HELLO', text: 'Hello', expiresAtMS: Date.now()+1000 } });
  assert.equal(s.candidate, null);
  for (const letter of ['C', 'P', 'J', 'Z', ' ', 'AU']) s = reduce(s, { type: 'add-letter', letter });
  assert.equal(s.spellingDraft, '');
  for (const letter of 'AURELIO') s = reduce(s, { type: 'add-letter', letter });
  assert.equal(s.spellingDraft, 'AURELIO');
  assert.equal(s.phrases.length, 0);
  assert.equal(s.speech, null);
  s = reduce(s, { type: 'confirm-spelling' });
  assert.equal(s.phrases[0].text, 'AURELIO');
  assert.equal(s.spellingDraft, '');
  assert.equal(reduce(s, { type: 'confirm-spelling' }).phrases.length, 1);
  assert.equal(initialSession().spellingDraft, '');
});

test('paused or covered camera cannot add/confirm letters and delete works', () => {
  let s = reduce(initialSession(), { type: 'recognition-mode', mode: 'spelling' });
  s = reduce(s, { type: 'add-letter', letter: 'A' });
  s = reduce(s, { type: 'pause' });
  assert.equal(reduce(s, { type: 'add-letter', letter: 'U' }).spellingDraft, 'A');
  assert.equal(reduce(s, { type: 'confirm-spelling' }).phrases.length, 0);
  s = reduce(s, { type: 'resume' });
  s = reduce(s, { type: 'open-sheet', sheet: 'detector' });
  assert.equal(reduce(s, { type: 'confirm-spelling' }).phrases.length, 0);
  s = reduce(s, { type: 'delete-letter' });
  assert.equal(s.spellingDraft, '');
});
