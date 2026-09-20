import test from 'node:test';
import assert from 'node:assert/strict';
import { initialSession, sessionReducer as reduce, type Session, type Action } from '../src/session/model.ts';
import { emptySentence, sentenceText, sentenceEmotion, MAX_SENTENCE_CHARACTERS } from '../src/session/sentence.ts';
import { translationFromPrediction, type SignLabel } from '../src/integrations/localSign.ts';
import { fetchSpeech } from '../src/integrations/speechTransport.ts';
import { conversationLayout } from '../src/session/conversationLayout.ts';
import type { Emotion } from '../src/integrations/contracts.ts';

const ready = () => reduce(initialSession(), { type: 'framing', framing: 'ready', captureId: 1 });
const target = (state: Session) => ({ draftId: state.sentence.id, revision: state.sentence.revision });
const commit = (state: Session) => reduce(state, { type: 'commit-sentence', ...target(state) });
function sign(state: Session, label: SignLabel, attemptId = (state.recognizedAttempt ?? 0) + 1, emotion: Emotion = 'neutral', phase: 'completed' | 'preview' = 'completed') {
  const event = translationFromPrediction({ captureId: state.captureId, engine: 'basic-temporal-v3', phase,
    attemptId, candidates: [{ label, distance: 0.1 }], label, matched: false, observedAtMS: Date.now(), emotion }, true, state.captureId)!;
  return reduce(state, { type: 'translation', captureId: state.captureId, event });
}
const sequence = (labels: SignLabel[], state = ready()) => labels.reduce((next, label) => sign(next, label), state);

test('four signs remain unspoken until one commit sends the entire sentence in one backend request', async () => {
  const draft = sequence(['TODAY', 'WE', 'SHOW', 'PHONE']);
  assert.deepEqual(draft.phrases, []);
  assert.equal(draft.speech, null);
  assert.equal(sentenceText(draft.sentence), 'Today we show the phone.');
  const state = commit(draft);
  assert.equal(state.phrases.length, 1);
  assert.deepEqual(state.phrases[0].tokens?.map(token => token.label), ['TODAY', 'WE', 'SHOW', 'PHONE']);
  assert.equal(sentenceText(state.sentence), '');
  let calls = 0;
  await fetchSpeech(state.speech!, { enabled: true, url: 'https://voice.example.test', token: 'test-token-at-least-24-characters' },
    new AbortController().signal, async (_url, init) => {
      calls++;
      assert.deepEqual(JSON.parse(String(init?.body)), { text: 'Today we show the phone.', emotion: 'neutral' });
      return Response.json({ audio_base64: 'SUQz' });
    });
  assert.equal(calls, 1);
});

test('formatter preserves multiword signs, repetitions, I, and missing information', () => {
  assert.equal(sentenceText(sequence(['HELLO', 'MY', 'NAME']).sentence), 'Hello my name.');
  assert.equal(sentenceText(sequence(['THANKYOU', 'ILOVEYOU']).sentence), 'Thank you I love you.');
  assert.equal(sentenceText(sequence(['PLEASE', 'PLEASE']).sentence), 'Please please.');
  assert.equal(sentenceText(sequence(['TODAY', 'WE', 'SHOW']).sentence), 'Today we show.');
  assert.equal(sentenceText(emptySentence()), '');
});

test('duplicate or stale commit actions cannot submit again or consume a newer draft', () => {
  const draft = sequence(['HELLO']);
  const action = { type: 'commit-sentence' as const, ...target(draft) };
  const committed = reduce(draft, action);
  assert.equal(reduce(committed, action), committed);
  const next = sign(committed, 'PHONE');
  assert.equal(reduce(next, action), next);
  const revised = sign(draft, 'THANKYOU');
  assert.equal(reduce(revised, action), revised);
  assert.equal(commit(ready()).phrases.length, 0);
});

test('undo, clear and commit keep the recognition watermark while allowing intentional repetitions', () => {
  const draft = sequence(['HELLO']);
  for (const type of ['undo-sign', 'clear-sentence', 'commit-sentence'] as const) {
    const cleared = reduce(draft, { type, ...target(draft) });
    assert.equal(sign(cleared, 'HELLO', 1), cleared);
    assert.equal(sign(cleared, 'HELLO', 1, 'neutral', 'preview'), cleared);
    assert.equal(sentenceText(sign(cleared, 'HELLO', 2).sentence), 'Hello.');
  }
});

test('next-sentence previews and drafts survive submission and playback completion', () => {
  let draft = sequence(['HELLO']);
  draft = sign(draft, 'THANKYOU', 2, 'neutral', 'preview');
  let state = commit(draft);
  assert.equal(state.signPreview?.text, 'Thank you.');
  const first = state.speech!;
  state = sign(state, 'THANKYOU', 2);
  assert.equal(state.speech, first);
  assert.equal(sentenceText(state.sentence), 'Thank you.');
  state = commit(state);
  assert.equal(state.speech, first);
  assert.equal(state.speechQueue.length, 1);
  state = sign(state, 'ILOVEYOU', 3);
  state = reduce(state, { type: 'speech-ended', id: first.id });
  assert.equal(state.speech?.text, 'Thank you.');
  assert.equal(sentenceText(state.sentence), 'I love you.');
  assert.equal(reduce(state, { type: 'speech-ended', id: first.id }), state);
});

test('pause, sheets, tracking loss and offline retain completed text and require explicit continuation', () => {
  const original = sequence(['HELLO', 'MY']);
  const interruptions: Action[] = [{ type: 'pause' }, { type: 'open-sheet', sheet: 'menu' },
    { type: 'framing', captureId: 1, framing: 'hands-missing' },
    { type: 'translation', captureId: 1, event: { type: 'offline' } },
    { type: 'recognition-mode', mode: 'spelling' }];
  for (const action of interruptions) {
    let state = reduce(original, action);
    assert.equal(sentenceText(state.sentence), 'Hello my.');
    assert.equal(state.sentence.needsContinuation, true);
    if (state.recognitionMode === 'spelling') state = reduce(state, { type: 'recognition-mode', mode: 'signs' });
    if (state.sheet) state = reduce(state, { type: 'close-sheet' });
    if (state.paused) state = reduce(state, { type: 'resume' });
    if (state.phase === 'offline') state = reduce(state, { type: 'retry' });
    state = reduce(state, { type: 'framing', framing: 'ready', captureId: state.captureId });
    assert.equal(sign(state, 'NAME'), state, 'new signs cannot silently join a retained draft');
    state = reduce(state, { type: 'continue-sentence', ...target(state) });
    state = reduce(state, { type: 'framing', framing: 'ready', captureId: state.captureId });
    state = sign(state, 'NAME');
    assert.equal(sentenceText(state.sentence), 'Hello my name.');
    assert.notEqual(state.sentence.tokens[0].captureId, state.sentence.tokens[2].captureId);
  }
});

test('retained drafts can be committed with hands out of frame but never while paused or covered', () => {
  const original = sequence(['HELLO']);
  const lost = reduce(original, { type: 'framing', captureId: 1, framing: 'hands-missing' });
  assert.equal(commit(lost).speech?.text, 'Hello.');
  for (const action of [{ type: 'pause' }, { type: 'open-sheet', sheet: 'menu' }] as const) {
    const blocked = reduce(original, action);
    assert.equal(commit(blocked), blocked);
  }
});

test('draft editing preserves source tokens and cannot silently append signs or speak', () => {
  const draft = sequence(['HELLO', 'MY', 'NAME']);
  const editor = reduce(draft, { type: 'open-sheet', sheet: 'sentence-editor' });
  const action = { type: 'edit-sentence' as const, ...target(editor), text: 'Hello, my name is Aurelio.' };
  const edited = reduce(editor, action);
  assert.equal(edited.speech, null);
  assert.deepEqual(edited.phrases, []);
  assert.equal(sentenceText(edited.sentence), action.text);
  assert.equal(edited.sentence.tokens, draft.sentence.tokens);
  const framed = reduce(edited, { type: 'framing', captureId: edited.captureId, framing: 'ready' });
  assert.equal(sign(framed, 'PHONE'), framed);
  assert.equal(reduce(framed, { type: 'undo-sign', ...target(framed) }), framed);
  assert.equal(commit(framed).speech?.text, action.text);
  assert.equal(reduce(editor, { ...action, revision: -1 }), editor);
});

test('typing a sentence from an empty draft works and preserves an explicit pause', () => {
  const editor = reduce(ready(), { type: 'open-sheet', sheet: 'sentence-editor' });
  const paused = reduce(editor, { type: 'pause' });
  const edited = reduce(paused, { type: 'edit-sentence', ...target(paused), text: 'My name is Aurelio.' });
  assert.equal(edited.paused, true);
  assert.equal(commit(edited), edited);
  const resumed = reduce(edited, { type: 'resume' });
  assert.equal(commit(resumed).speech?.text, 'My name is Aurelio.');
});

test('final-text limit never truncates a draft and rejects overlong edits', () => {
  let draft = ready();
  for (let i = 0; i < 60; i++) draft = sign(draft, 'ILOVEYOU');
  const text = sentenceText(draft.sentence);
  assert.ok(text.length > MAX_SENTENCE_CHARACTERS);
  assert.equal(commit(draft), draft);
  assert.equal(sentenceText(draft.sentence), text);
  const editor = reduce(draft, { type: 'open-sheet', sheet: 'sentence-editor' });
  assert.equal(reduce(editor, { type: 'edit-sentence', ...target(editor), text: 'x'.repeat(501) }), editor);
  assert.equal(reduce(editor, { type: 'edit-sentence', ...target(editor), text: ' ' }), editor);
  const edited = reduce(editor, { type: 'edit-sentence', ...target(editor), text: 'x'.repeat(500) });
  const committed = commit(edited);
  assert.equal(committed.speech?.text.length, 500);
  assert.equal(reduce(committed, { type: 'correct', text: 'x'.repeat(501) }), committed);
});

test('sentence delivery uses token expressions, freezes them on commit and resolves ties to neutral', () => {
  let state = sign(ready(), 'HELLO', 1, 'joy');
  state = sign(state, 'THANKYOU', 2, 'joy');
  state = sign(state, 'ILOVEYOU', 3, 'sadness');
  assert.equal(sentenceEmotion(state.sentence.tokens), 'joy');
  assert.equal(sentenceEmotion(state.sentence.tokens.slice(1)), 'neutral');
  assert.equal(sentenceEmotion([]), 'neutral');
  state = reduce(state, { type: 'expression', event: { captureId: 1, observedAtMS: Date.now(), status: 'active', emotion: 'anger' } });
  state = commit(state);
  assert.equal(state.speech?.emotion, 'joy');
  const played = reduce(state, { type: 'speech-ended', id: state.speech!.id });
  assert.equal(reduce(played, { type: 'replay' }).speech?.emotion, 'joy');
  assert.equal(reduce(played, { type: 'correct', text: 'Thank you.' }).speech?.emotion, 'joy');
});

test('mute and voice failure retain both captions and the next draft without restarting old audio', () => {
  let state = commit(sequence(['HELLO']));
  state = sign(state, 'PHONE');
  const failed = reduce(state, { type: 'speech-ended', id: state.speech!.id, failed: true });
  assert.equal(failed.phrases[0].status, 'failed');
  assert.equal(sentenceText(failed.sentence), 'Phone.');
  const muted = reduce(state, { type: 'mute' });
  assert.equal(sentenceText(muted.sentence), 'Phone.');
  const saved = commit(muted);
  assert.equal(saved.speech, null);
  assert.equal(saved.phrases.length, 2);
  assert.equal(reduce(saved, { type: 'mute' }).speech, null);
});

test('sentence controls have reserved space while goose height is stable across font sizes', () => {
  for (const height of [400, 520, 660, 800]) {
    const normal = conversationLayout(height, 1, 'listening', 390, true);
    for (const fontScale of [1, 1.3, 1.8, 2.4]) {
      const layout = conversationLayout(height, fontScale, 'listening', 390, true);
      assert.equal(layout.goose, normal.goose);
      for (const focus of ['thinking', 'speaking'] as const) {
        assert.deepEqual(conversationLayout(height, fontScale, focus, 390, true), layout);
      }
      assert.ok(layout.caption >= height * 0.4);
      assert.ok(layout.camera >= height * 0.17 - 1e-6);
      assert.ok(Math.abs(layout.camera + layout.goose + layout.caption + layout.clearance - height) < 1e-6);
    }
  }
});
