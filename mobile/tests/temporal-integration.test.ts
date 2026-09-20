import test from 'node:test';
import assert from 'node:assert/strict';
import { translationFromPrediction, signText } from '../src/integrations/localSign.ts';
import { initialSession, sessionReducer as reduce } from '../src/session/model.ts';

test('all 11 native temporal labels preview silently and speak on completion', () => {
  assert.equal(Object.keys(signText).length, 11);
  for (const label of Object.keys(signText)) {
    const now = Date.now();
    const event = translationFromPrediction({ captureId: 1, label, observedAtMS: now,
      engine: 'basic-temporal-v3', phase: 'preview', attemptId: 1, matched: false,
      candidates: [{ label, distance: .1 }] }, true, 1)!;
    let s = reduce({ ...initialSession(), muted: true }, { type: 'framing', framing: 'ready', captureId: 1 });
    s = reduce(s, { type: 'translation', captureId: 1, event });
    assert.equal(s.signPreview?.text, signText[label as keyof typeof signText]);
    assert.equal(s.speech, null);
    assert.equal(s.phrases.length, 0);
    const completed = translationFromPrediction({ captureId: 1, label, observedAtMS: Date.now(),
      engine: 'basic-temporal-v3', phase: 'completed', attemptId: 1, matched: false,
      candidates: [{ label, distance: .1 }] }, true, 1)!;
    s = reduce(s, { type: 'translation', captureId: 1, event: completed });
    assert.equal(s.phrases[0].text, signText[label as keyof typeof signText]);
    assert.equal(s.speech, null);
  }
});

test('mode change invalidates old detector epoch and spelling stays explicit and restricted', () => {
  let s = reduce(initialSession(), { type: 'recognition-mode', mode: 'spelling' });
  assert.equal(s.captureId, 2);
  const event = translationFromPrediction({ captureId: 1, label: 'HELLO', observedAtMS: Date.now(),
    engine: 'basic-temporal-v3', phase: 'preview', attemptId: 1, matched: false,
    candidates: [{ label: 'HELLO', distance: .1 }] }, true, 1)!;
  s = reduce(s, { type: 'translation', captureId: 1, event });
  assert.equal(s.signPreview, null);
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


test('sign predictions cannot create captions or speech while spelling in the current generation', () => {
  const spelling = reduce(initialSession(), { type: 'recognition-mode', mode: 'spelling' });
  const state = reduce(spelling, { type: 'framing', framing: 'ready', captureId: spelling.captureId });
  for (const phase of ['preview', 'completed'] as const) {
    const event = translationFromPrediction({ captureId: state.captureId, label: 'HELLO', observedAtMS: Date.now(),
      engine: 'basic-temporal-v3', phase, attemptId: 1, matched: false,
      candidates: [{ label: 'HELLO', distance: .1 }] }, true, state.captureId)!;
    assert.equal(reduce(state, { type: 'translation', captureId: state.captureId, event }), state);
  }
  const signs = reduce(state, { type: 'recognition-mode', mode: 'signs' });
  const ready = reduce(signs, { type: 'framing', framing: 'ready', captureId: signs.captureId });
  const event = translationFromPrediction({ captureId: ready.captureId, label: 'HELLO', observedAtMS: Date.now(),
    engine: 'basic-temporal-v3', phase: 'completed', attemptId: 1, matched: false,
    candidates: [{ label: 'HELLO', distance: .1 }] }, true, ready.captureId)!;
  const spoken = reduce(ready, { type: 'translation', captureId: ready.captureId, event });
  assert.equal(spoken.speech?.text, 'Hello.');
  assert.equal(spoken.phrases[0].text, 'Hello.');
});
