import test from 'node:test';
import assert from 'node:assert/strict';
import { canCapture, initialSession, sessionReducer as reduce, type Session } from '../src/session/model.ts';

function ready() {
  const state = initialSession();
  return reduce(state, { type: 'framing', framing: 'ready', captureId: state.captureId });
}
function accept(state: Session, id = 'phrase-1', text = 'Hello there.') {
  return reduce(state, { type: 'translation', captureId: state.captureId, event: { type: 'accepted', id, text, emotion: 'neutral' } });
}

test('drafts and uncertain results never enter the transcript or speak', () => {
  let state = ready();
  state = reduce(state, { type: 'translation', captureId: state.captureId, event: { type: 'draft', text: 'Maybe…' } });
  assert.equal(state.speech, null);
  state = reduce(state, { type: 'translation', captureId: state.captureId, event: { type: 'uncertain' } });
  assert.equal(state.draft, '');
  assert.equal(state.phrases.length, 0);
  assert.equal(state.speech, null);
});

test('stable accepted IDs deduplicate, while subsequent phrases wait for playback', () => {
  const state = accept(ready());
  assert.equal(accept(state), state);
  const next = accept(state, 'phrase-2', 'Nice to meet you.');
  assert.equal(next.speech?.phraseId, 'phrase-1');
  const finished = reduce(next, { type: 'speech-ended', id: state.speech!.id });
  assert.equal(finished.speech?.phraseId, 'phrase-2');
  assert.equal(finished.phrases[0].status, 'played');
});

test('pause cancels playback and queued speech, and rejects late translation/completion', () => {
  const before = accept(accept(ready()), 'phrase-2');
  const paused = reduce(before, { type: 'pause' });
  assert.equal(canCapture(paused), false);
  assert.equal(paused.speech, null);
  assert.deepEqual(paused.speechQueue, []);
  assert.equal(paused.phrases[0].status, 'interrupted');
  assert.equal(reduce(paused, { type: 'speech-ended', id: before.speech!.id }), paused);
  const resumed = reduce(paused, { type: 'resume' });
  const late = reduce(resumed, { type: 'translation', captureId: before.captureId, event: { type: 'accepted', id: 'late', text: 'Stale', emotion: 'neutral' } });
  assert.equal(late, resumed);
});

test('loss of framing invalidates pending recognition but preserves accepted words', () => {
  const before = accept(ready());
  const state = reduce(before, { type: 'framing', framing: 'hands-missing', captureId: before.captureId });
  assert.equal(state.phrases.length, 1);
  assert.equal(state.speech, before.speech);
  assert.notEqual(state.captureId, before.captureId);
  assert.equal(accept(state, 'bad'), state);
});

test('sheet capture stays stopped and closing preserves an explicit pause', () => {
  const paused = reduce(ready(), { type: 'pause' });
  const sheet = reduce(paused, { type: 'open-sheet', sheet: 'transcript' });
  assert.equal(canCapture(sheet), false);
  assert.equal(canCapture(reduce(sheet, { type: 'close-sheet' })), false);
});

test('correction retains original wording, cancels old playback, and speaks the revision', () => {
  const old = accept(ready());
  const editing = reduce(old, { type: 'open-sheet', sheet: 'correction' });
  assert.equal(editing.speech, null);
  assert.equal(reduce(editing, { type: 'correct', text: '  ' }), editing);
  const revised = reduce(editing, { type: 'correct', text: 'Hello Sunny.' });
  assert.equal(revised.phrases[0].original, 'Hello there.');
  assert.equal(revised.speech?.text, 'Hello Sunny.');
  assert.equal(reduce(revised, { type: 'speech-ended', id: old.speech!.id }), revised);
  const twice = reduce(revised, { type: 'correct', text: 'Good morning.' });
  assert.equal(twice.phrases[0].original, 'Hello there.');
});

test('mute keeps captions and does not replay a backlog when reenabled', () => {
  const muted = reduce(ready(), { type: 'mute' });
  const state = accept(muted);
  assert.equal(state.phrases.length, 1);
  assert.equal(state.speech, null);
  assert.equal(reduce(state, { type: 'mute' }).speech, null);
});

test('enabling voice unmutes so the next completed sign speaks without a replay tap', () => {
  const muted = reduce(ready(), { type: 'disable-voice' });
  const silent = accept(muted);
  assert.equal(silent.speech, null);
  const enabled = reduce(silent, { type: 'enable-voice' });
  assert.equal(enabled.muted, false);
  assert.equal(enabled.speech, null);
  const spoken = accept(enabled, 'phrase-2', 'Please.');
  assert.equal(spoken.speech?.text, 'Please.');
});

test('replay does not cancel automatic playback of the same phrase', () => {
  const state = accept(ready());
  assert.equal(reduce(state, { type: 'replay' }).speech?.id, state.speech?.id);
});

test('voice failure preserves caption, and reconnect starts a new generation', () => {
  const before = accept(ready());
  const failed = reduce(before, { type: 'speech-ended', id: before.speech!.id, failed: true });
  assert.equal(failed.phase, 'voice-error');
  assert.equal(failed.phrases[0].text, 'Hello there.');
  const offline = reduce(failed, { type: 'translation', captureId: failed.captureId, event: { type: 'offline' } });
  assert.equal(canCapture(offline), false);
  const retried = reduce(offline, { type: 'retry' });
  assert.equal(retried.framing, 'finding');
  assert.notEqual(retried.captureId, offline.captureId);
});
