import test from 'node:test';
import assert from 'node:assert/strict';
import { initialSession, sessionReducer as reduce, type Session } from '../src/session/model.ts';
import { emptySentence, sentenceText, sentenceEmotion, MAX_SENTENCE_CHARACTERS, type SentenceToken } from '../src/session/sentence.ts';
import { translationFromPrediction, signText, type SignLabel } from '../src/integrations/localSign.ts';
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
const draft = (labels: SignLabel[], emotion: Emotion = 'neutral'): SentenceToken[] => labels.map((label, i) => ({
  label, text: signText[label], captureId: 1, attemptId: i + 1, observedAtMS: i, emotion,
}));

test('each completed sign speaks immediately instead of waiting for a sentence button', async () => {
  const state = sequence(['TODAY', 'WE', 'SHOW', 'PHONE']);
  assert.deepEqual(state.phrases.map(phrase => phrase.text), ['Today', 'We', 'Show', 'Phone']);
  assert.equal(state.speech?.text, 'Today');
  assert.equal(state.speechQueue.length, 3);
  let calls = 0;
  await fetchSpeech(state.speech!, { enabled: true, url: 'https://voice.example.test', token: 'test-token-at-least-24-characters' },
    new AbortController().signal, async (_url, init) => {
      calls++;
      assert.deepEqual(JSON.parse(String(init?.body)), { text: 'Today', emotion: 'neutral' });
      return Response.json({ audio_base64: 'SUQz' });
    });
  assert.equal(calls, 1);
});

test('formatter preserves multiword signs, repetitions, I, and missing information', () => {
  const text = (labels: SignLabel[]) => sentenceText({ ...emptySentence(), tokens: draft(labels) });
  assert.equal(text(['HELLO', 'MY', 'NAME']), 'Hello my name.');
  assert.equal(text(['THANKYOU', 'ILOVEYOU']), 'Thank you I love you.');
  assert.equal(text(['PLEASE', 'PLEASE']), 'Please please.');
  assert.equal(text(['TODAY', 'WE', 'SHOW']), 'Today we show.');
  assert.equal(sentenceText({ ...emptySentence(), tokens: draft(['TODAY', 'WE', 'SHOW', 'PHONE']) }), 'Today we show the phone.');
  assert.equal(sentenceText(emptySentence()), '');
});

test('holding a completed sign does not repeat it; a new attempt queues the next word', () => {
  const first = sequence(['HELLO']);
  assert.equal(sign(first, 'HELLO', 1), first);
  assert.equal(sign(first, 'HELLO', 1, 'neutral', 'preview'), first);
  const next = sign(first, 'HELLO', 2);
  assert.equal(next.phrases.length, 2);
  assert.equal(next.speech, first.speech);
  assert.equal(next.speechQueue.length, 1);
});

test('next-sign previews survive the previous word and queue after it', () => {
  let state = sequence(['HELLO']);
  state = sign(state, 'THANKYOU', 2, 'neutral', 'preview');
  assert.equal(state.signPreview?.text, 'Thank you.');
  const first = state.speech!;
  state = sign(state, 'THANKYOU', 2);
  assert.equal(state.speech, first);
  assert.equal(state.speechQueue.length, 1);
  state = reduce(state, { type: 'speech-ended', id: first.id });
  assert.equal(state.speech?.text, 'Thank you.');
  assert.equal(reduce(state, { type: 'speech-ended', id: first.id }), state);
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

test('final-text limit never truncates a typed sentence and rejects overlong edits', () => {
  const editor = reduce(ready(), { type: 'open-sheet', sheet: 'sentence-editor' });
  assert.equal(reduce(editor, { type: 'edit-sentence', ...target(editor), text: 'x'.repeat(501) }), editor);
  assert.equal(reduce(editor, { type: 'edit-sentence', ...target(editor), text: ' ' }), editor);
  const edited = reduce(editor, { type: 'edit-sentence', ...target(editor), text: 'x'.repeat(500) });
  const committed = commit(edited);
  assert.equal(committed.speech?.text.length, MAX_SENTENCE_CHARACTERS);
  assert.equal(reduce(committed, { type: 'correct', text: 'x'.repeat(501) }), committed);
});

test('completed signs keep their own expression and freeze it on the spoken phrase', () => {
  let state = sign(ready(), 'HELLO', 1, 'joy');
  state = sign(state, 'THANKYOU', 2, 'joy');
  state = sign(state, 'ILOVEYOU', 3, 'sadness');
  assert.equal(sentenceEmotion(draft(['HELLO', 'THANKYOU'], 'joy')), 'joy');
  assert.equal(sentenceEmotion([...draft(['THANKYOU'], 'joy'), ...draft(['ILOVEYOU'], 'sadness')]), 'neutral');
  assert.equal(sentenceEmotion([]), 'neutral');
  assert.equal(state.phrases[0].emotion, 'joy');
  assert.equal(state.speech?.emotion, 'joy');
  const played = reduce(state, { type: 'speech-ended', id: state.speech!.id });
  assert.equal(played.speech?.emotion, 'joy');
  assert.equal(reduce(played, { type: 'replay' }).speech?.emotion, 'sadness');
});

test('mute and voice failure retain captions without restarting old audio', () => {
  let state = sequence(['HELLO']);
  state = sign(state, 'PHONE');
  const failed = reduce(state, { type: 'speech-ended', id: state.speech!.id, failed: true });
  assert.equal(failed.phrases[0].status, 'failed');
  assert.equal(failed.phrases[1].text, 'Phone');
  const muted = reduce(state, { type: 'mute' });
  assert.equal(muted.phrases.length, 2);
  assert.equal(muted.speech, null);
  assert.equal(reduce(muted, { type: 'mute' }).speech, null);
});

test('live captions stay compact while leftover space stays with the goose', () => {
  for (const height of [400, 520, 660, 800]) {
    const listening = conversationLayout(height, 1, 'listening', 390);
    for (const fontScale of [1, 1.3, 1.8, 2.4]) {
      const layout = conversationLayout(height, fontScale, 'listening', 390);
      assert.ok(layout.caption <= height * 0.22 + 1e-6);
      assert.ok(layout.goose <= listening.goose + 1e-6);
      for (const focus of ['thinking', 'speaking'] as const) {
        assert.deepEqual(conversationLayout(height, fontScale, focus, 390), layout);
      }
      assert.ok(Math.abs(layout.camera + layout.goose + layout.caption + layout.clearance - height) < 1e-6);
    }
  }
});
