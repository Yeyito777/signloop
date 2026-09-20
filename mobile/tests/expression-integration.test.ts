import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { emotions, type Emotion } from '../../goose/src/emotion.ts';
import { expressionFromCamera, conversationEmotion, EXPRESSION_FRESH_MS } from '../src/integrations/expression.ts';
import { candidateFromPrediction } from '../src/integrations/localSign.ts';
import { goosePresentation } from '../src/integrations/goosePresentation.ts';
import { initialSession, sessionReducer as reduce, type Session } from '../src/session/model.ts';
import { createVoiceAdapter } from '../src/integrations/voiceLifecycle.ts';
import { fetchSpeech } from '../src/integrations/speechTransport.ts';
import { setVoiceSettings } from '../src/integrations/voiceSettings.ts';
import type { ExpressionEvent } from '../modules/signloop-camera/events.ts';

const ready = () => reduce(initialSession(), { type: 'framing', captureId: 1, framing: 'ready' });
const expression = (emotion: Emotion, at = Date.now(), captureId = 1): ExpressionEvent => ({
  captureId, observedAtMS: at, emotion, status: emotion === 'neutral' ? 'neutral' : 'active',
});
function offer(state: Session, emotion: Emotion, attemptId = 1, observedAtMS = Date.now()) {
  const event = candidateFromPrediction({ engine: 'basic-temporal-v3', phase: 'completed',
    attemptId, captureId: state.captureId, observedAtMS, matched: false,
    label: 'HELLO', candidates: [{ label: 'HELLO', distance: 0.1 }], emotion }, true, state.captureId)!;
  return reduce(state, { type: 'translation', captureId: state.captureId, event });
}
function confirm(state: Session) {
  const attemptId = state.candidate!.attemptId;
  return reduce(reduce(state, { type: 'select-candidate', attemptId, label: 'HELLO' }), { type: 'confirm-candidate', attemptId });
}
afterEach(() => setVoiceSettings({ url: '', token: '', enabled: false }));

test('all six native expression labels reach both the goose and the backend request unchanged', async () => {
  setVoiceSettings({ url: 'https://voice.example.test', token: 'test-token-with-at-least-24-characters', enabled: true });
  for (const emotion of emotions) {
    let state = confirm(offer(ready(), emotion));
    assert.equal(state.phrases[0].emotion, emotion);
    const speech = state.speech!;
    let calls = 0;
    const voice = createVoiceAdapter((request, settings, signal) => fetchSpeech(request, settings, signal,
      async (_url, init) => {
        calls++;
        assert.deepEqual(JSON.parse(String(init?.body)), { text: 'Hello.', emotion });
        return Response.json({ audio_base64: 'SUQz' });
      }), async (_clip, _signal, onStart) => { onStart?.(); });
    await voice.speak(speech, new AbortController().signal, () => {
      state = reduce(state, { type: 'speech-started', id: speech.id });
      assert.equal(conversationEmotion(state), emotion);
      assert.equal(goosePresentation('speaking', conversationEmotion(state)).emotion,
        emotion === 'neutral' ? undefined : emotion);
    });
    assert.equal(calls, 1);
    state = reduce(state, { type: 'speech-ended', id: speech.id });
    assert.equal(conversationEmotion(state), 'neutral', 'completed phrases cannot leave a stuck pose');
  }
});

test('selection freezes the signing expression even if the face and later rankings change before confirmation', context => {
  context.mock.timers.enable({ apis: ['Date'], now: Date.now() });
  let state = offer(ready(), 'joy');
  state = reduce(state, { type: 'select-candidate', attemptId: 1, label: 'HELLO' });
  context.mock.timers.tick(500);
  state = reduce(state, { type: 'expression', event: expression('sadness') });
  state = offer(state, 'sadness', 2);
  assert.equal(state.candidate?.emotion, 'joy');
  state = reduce(state, { type: 'confirm-candidate', attemptId: 1 });
  assert.equal(state.speech?.emotion, 'joy');
});

test('new live expressions do not change or restart prepared speech, and queued phrases keep their own emotion', context => {
  context.mock.timers.enable({ apis: ['Date'], now: Date.now() });
  let state = confirm(offer(ready(), 'anger'));
  const first = state.speech!;
  context.mock.timers.tick(50);
  state = reduce(state, { type: 'expression', event: expression('joy') });
  assert.equal(state.speech, first);
  assert.equal(conversationEmotion(state), 'anger');
  state = confirm(offer(state, 'disgust', 2));
  assert.equal(conversationEmotion(state), 'anger');
  state = reduce(state, { type: 'speech-ended', id: first.id });
  assert.equal(state.speech?.emotion, 'disgust');
  assert.equal(conversationEmotion(state), 'disgust');
  state = reduce(state, { type: 'speech-ended', id: state.speech!.id });
  assert.equal(conversationEmotion(state), 'joy');
});

test('replay and corrections retain the original expression', () => {
  let state = confirm(offer(ready(), 'fear'));
  state = reduce(state, { type: 'speech-ended', id: state.speech!.id });
  state = reduce(state, { type: 'expression', event: expression('joy') });
  state = reduce(state, { type: 'replay' });
  assert.equal(state.speech?.emotion, 'fear');
  state = reduce(state, { type: 'correct', text: 'Thank you.' });
  assert.deepEqual({ text: state.speech?.text, emotion: state.speech?.emotion }, { text: 'Thank you.', emotion: 'fear' });
});

test('fresh expression changes drive the silent live goose without creating a phrase or voice request', () => {
  let state = { ...ready(), muted: true };
  for (const [index, emotion] of emotions.entries()) {
    state = reduce(state, { type: 'expression', event: expression(emotion, Date.now() + index) });
    assert.equal(conversationEmotion(state), emotion);
    assert.equal(state.speech, null);
    assert.deepEqual(state.phrases, []);
  }
});

test('expression loss, ambiguity and missing setup immediately neutralize the live goose', () => {
  const state = reduce(ready(), { type: 'expression', event: expression('joy') });
  for (const status of ['no-face', 'unknown', 'ambiguous', 'holding', 'wrong-camera', 'face-forward', 'no-profile', 'profile-invalid', 'model-missing', 'unavailable'] as const) {
    const next = reduce(state, { type: 'expression', event: { ...expression('joy', Date.now() + 1), status } });
    assert.equal(conversationEmotion(next), 'neutral');
  }
});

test('stale, future, out-of-order and previous-generation events cannot resurrect an expression', context => {
  const now = Date.now();
  context.mock.timers.enable({ apis: ['Date'], now });
  let state = reduce(ready(), { type: 'expression', event: expression('joy') });
  for (const invalid of [expression('anger', now - 1), expression('anger', now + 101),
    expression('anger', now, 0), expression('anger', NaN)]) {
    assert.equal(reduce(state, { type: 'expression', event: invalid }), state);
  }
  context.mock.timers.tick(EXPRESSION_FRESH_MS);
  state = reduce(state, { type: 'expire-expression', observedAtMS: now });
  assert.equal(conversationEmotion(state), 'neutral');
  context.mock.timers.tick(1);
  assert.equal(expressionFromCamera(expression('joy', now), 1), null);
  state = reduce(state, { type: 'expression', event: expression('fear') });
  assert.equal(reduce(state, { type: 'expire-expression', observedAtMS: now }), state);
  for (const action of [{ type: 'pause' }, { type: 'open-sheet', sheet: 'menu' }, { type: 'retry' },
    { type: 'framing', captureId: 1, framing: 'hands-missing' }] as const) {
    const cleared = reduce(state, action);
    assert.equal(conversationEmotion(cleared), 'neutral');
    assert.equal(reduce(cleared, { type: 'expression', event: expression('joy') }), cleared);
  }
});

test('malformed labels abstain and unsupported voice emotions never reach the network', async () => {
  const result = expressionFromCamera({ ...expression('joy'), emotion: 'constructor' } as unknown as ExpressionEvent, 1);
  assert.equal(result?.emotion, 'neutral');
  assert.equal(result?.status, 'unavailable');
  await assert.rejects(fetchSpeech({ text: 'Hello.', emotion: 'happy' as Emotion },
    { url: 'https://voice.example.test', token: 'test-token-at-least-24-characters', enabled: true }, new AbortController().signal,
    async () => { assert.fail('invalid emotion reached network'); }), /emotion/);
});
