import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { URL } from 'node:url';
import { translationFromPrediction, signText, SIGN_FRESH_MS } from '../src/integrations/localSign.ts';
import { cameraAvailability, framingFromCamera } from '../src/integrations/cameraStatus.ts';
import { initialSession, sessionReducer as reduce } from '../src/session/model.ts';
import type { SignPredictionEvent, CameraStatus } from '../modules/signloop-camera/events.ts';

const event = (overrides: Partial<SignPredictionEvent> = {}): SignPredictionEvent => ({
  engine: 'basic-temporal-v3', phase: 'completed', attemptId: 1, captureId: 1,
  candidates: [{ label: 'HELLO', distance: 0.08 }, { label: 'THANKYOU', distance: 0.09 }, { label: 'PLEASE', distance: 0.11 }],
  label: 'HELLO', matched: false, observedAtMS: Date.now(), ...overrides,
});
const ready = () => reduce(initialSession(), { type: 'framing', framing: 'ready', captureId: 1 });
function receive(state = ready(), native = event()) {
  const translation = translationFromPrediction(native, true, state.captureId);
  return translation ? reduce(state, { type: 'translation', captureId: state.captureId, event: translation }) : state;
}

test('every native presentation label speaks its canonical caption on completion', () => {
  const swift = readFileSync(new URL('../../ios/Signloop/BasicSignMatcher.swift', import.meta.url), 'utf8');
  const vocabulary = swift.match(/static let presentationVocabulary = \[([^\]]+)\]/)![1];
  const nativeLabels = [...vocabulary.matchAll(/"([A-Z]+)"/g)].map(match => match[1]);
  assert.deepEqual(Object.keys(signText), nativeLabels, 'JS and the actual native vocabulary must agree');
  for (const label of nativeLabels) {
    const state = receive(ready(), event({ label, candidates: [{ label, distance: 0.1 }] }));
    assert.equal(state.phrases[0].text, signText[label as keyof typeof signText]);
    assert.equal(state.speech?.text, signText[label as keyof typeof signText]);
    assert.equal(state.signPreview, null);
  }
});

test('completion picks exactly the best match even when the native rolling-only matched flag is false', () => {
  for (const matched of [false, true]) {
    const state = receive(ready(), event({ matched }));
    assert.deepEqual(state.phrases.map(p => p.text), ['Hello.']);
    assert.equal(state.speech?.text, 'Hello.');
    assert.deepEqual(state.speechQueue, []);
  }
});

test('rolling rankings show one live guess without speaking before gesture completion', () => {
  const state = receive(ready(), event({ phase: 'preview', matched: true }));
  assert.equal(state.signPreview?.text, 'Hello.');
  assert.equal(state.phrases.length, 0);
  assert.equal(state.speech, null);
  assert.equal(state.sentence.tokens.length, 0);
  assert.equal(receive(state).phrases[0].text, 'Hello.');
  assert.equal(receive(state).speech?.text, 'Hello.');
});

test('live guesses follow fresh input and reject older or duplicate previews', context => {
  context.mock.timers.enable({ apis: ['Date'], now: Date.now() });
  const first = event({ phase: 'preview' });
  const state = receive(ready(), first);
  context.mock.timers.tick(100);
  const next = receive(state, event({ phase: 'preview', label: 'THANKYOU', candidates: [{ label: 'THANKYOU', distance: 0.05 }] }));
  assert.equal(next.signPreview?.text, 'Thank you.');
  assert.equal(receive(next, first), next);
  assert.equal(receive(state, first), state);
});

test('stalled previews expire without speaking and older timers cannot clear fresh input', context => {
  const now = Date.now();
  context.mock.timers.enable({ apis: ['Date'], now });
  const state = receive(ready(), event({ phase: 'preview' }));
  const expiry = { type: 'expire-preview' as const, attemptId: 1, observedAtMS: now };
  assert.equal(reduce(state, expiry), state);
  context.mock.timers.tick(SIGN_FRESH_MS - 1);
  const fresh = receive(state, event({ phase: 'preview' }));
  context.mock.timers.tick(1);
  assert.equal(reduce(fresh, expiry), fresh);
  const expired = reduce(state, expiry);
  assert.equal(expired.signPreview, null);
  assert.equal(expired.speech, null);
  assert.deepEqual(expired.phrases, []);
});

test('duplicates and late previews cannot repeat a completed attempt; a new attempt can repeat the word', () => {
  const spoken = receive();
  for (const phase of ['preview', 'completed'] as const) assert.equal(receive(spoken, event({ phase })), spoken);
  const cleared = reduce(spoken, { type: 'translation', captureId: 1, event: { type: 'clear-preview' } });
  assert.equal(receive(cleared), cleared);
  const repeated = receive(cleared, event({ attemptId: 2 }));
  assert.deepEqual(repeated.phrases.map(p => p.text), ['Hello.', 'Hello.']);
  assert.equal(repeated.speech, spoken.speech);
  assert.equal(repeated.speechQueue.length, 1);
  assert.equal(receive(repeated, event({ attemptId: 1 })), repeated);
});

test('completed gestures preserve a newer live preview and queue speech in order', () => {
  const preview = receive(ready(), event({ phase: 'preview', attemptId: 2, label: 'PLEASE', candidates: [{ label: 'PLEASE', distance: 0.1 }] }));
  const first = receive(preview);
  assert.equal(first.signPreview?.text, 'Please.');
  const second = receive(first, event({ attemptId: 2, label: 'PLEASE', candidates: [{ label: 'PLEASE', distance: 0.1 }] }));
  assert.equal(second.signPreview, null);
  assert.equal(second.speech?.text, 'Hello.');
  const finished = reduce(second, { type: 'speech-ended', id: second.speech!.id });
  assert.equal(finished.speech?.text, 'Please.');
  assert.equal(finished.phrases[0].status, 'played');
});

test('a result that becomes stale before reducer delivery cannot trigger speech', context => {
  context.mock.timers.enable({ apis: ['Date'], now: Date.now() });
  const translation = translationFromPrediction(event(), true, 1)!;
  context.mock.timers.tick(SIGN_FRESH_MS);
  const state = ready();
  assert.equal(reduce(state, { type: 'translation', captureId: 1, event: translation }), state);
});

test('native invalidations, malformed rankings and stale observations clear only the live preview', () => {
  const invalid: Partial<SignPredictionEvent>[] = [
    { phase: 'cleared' }, { phase: 'old' as 'completed' }, { engine: 'old-model' as 'basic-temporal-v3' },
    { label: null }, { label: 'UNKNOWN' }, { label: 'constructor' }, { matched: undefined },
    { observedAtMS: NaN }, { observedAtMS: Date.now() - 2000 }, { observedAtMS: Date.now() + 2000 },
    { attemptId: null }, { attemptId: 0 }, { attemptId: 1.5 }, { candidates: [] },
    { candidates: [{ label: 'HELLO', distance: NaN }] }, { candidates: [{ label: 'HELLO', distance: -1 }] },
    { candidates: [{ label: 'HELLO', distance: 0 }, { label: 'UNKNOWN', distance: 1 }] },
    { candidates: [{ label: 'HELLO', distance: 0 }, { label: 'HELLO', distance: 1 }] },
    { candidates: [{ label: 'HELLO', distance: 1 }, { label: 'PLEASE', distance: 0 }] },
    { candidates: [{ label: 'PLEASE', distance: 0 }] }, { candidates: Array(4).fill({ label: 'HELLO', distance: 0 }) },
  ];
  const speaking = receive();
  for (const changes of invalid) {
    assert.deepEqual(translationFromPrediction(event(changes), true, 1), { type: 'clear-preview' });
    const next = receive(speaking, event(changes));
    assert.equal(next.speech, speaking.speech);
    assert.equal(next.phrases, speaking.phrases);
  }
  assert.equal(translationFromPrediction(event(), false, 1), null);
  assert.equal(translationFromPrediction(event(), true, 2), null);
});

test('an old native binary is diagnosed before trying its incompatible view', () => {
  assert.equal(cameraAvailability(null), 'camera-unavailable');
  assert.equal(cameraAvailability({}), 'camera-update-required');
  for (const recognitionVersion of [1, 2, 3, 4]) {
    assert.equal(cameraAvailability({ recognitionVersion }), 'camera-update-required');
  }
  assert.equal(cameraAvailability({ recognitionVersion: 5 }), null);
});

test('setup failures and missing shoulders clear guesses and invalidate late completions', () => {
  const preview = receive(ready(), event({ phase: 'preview' }));
  const states = {
    'references-missing': 'recognizer-missing', 'references-invalid': 'recognizer-error',
    'model-missing': 'camera-model-missing', 'recognizer-loading': 'recognizer-loading', 'body-missing': 'body-missing',
  } as const;
  for (const [status, expected] of Object.entries(states)) {
    const native = { captureId: 1, status: status as CameraStatus, handCount: 1, message: '' };
    const framing = framingFromCamera(native, true, 1)!;
    assert.equal(framing, expected);
    assert.equal(framingFromCamera(native, true, 2), null);
    const next = reduce(preview, { type: 'framing', captureId: 1, framing });
    assert.equal(next.signPreview, null);
    assert.equal(next.phrases.length, 0);
    assert.equal(receive(next, event()), next);
  }
});

test('resuming uses a fresh capture generation and permits a new completed sign', () => {
  const spoken = receive();
  const resumed = reduce(reduce(spoken, { type: 'pause' }), { type: 'resume' });
  const state = reduce(resumed, { type: 'framing', captureId: resumed.captureId, framing: 'ready' });
  assert.equal(receive(state, event()), state);
  const next = receive(state, event({ captureId: state.captureId }));
  assert.equal(next.phrases.length, 2);
  assert.notEqual(next.phrases[0].id, next.phrases[1].id);
});
