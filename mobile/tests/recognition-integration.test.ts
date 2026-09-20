import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { URL } from 'node:url';
import { candidateFromPrediction, signText, SIGN_REVIEW_MS } from '../src/integrations/localSign.ts';
import { cameraAvailability, framingFromCamera } from '../src/integrations/cameraStatus.ts';
import { initialSession, sessionReducer as reduce } from '../src/session/model.ts';
import type { SignPredictionEvent, CameraStatus } from '../modules/signloop-camera/events.ts';

const event = (label: string | null, matched = true): SignPredictionEvent => ({
  engine: 'basic-temporal-v2', phase: 'completed', attemptId: 1,
  candidates: label ? [{ label, distance: 0.1 }] : [], captureId: 1, label, matched, observedAtMS: Date.now(),
});
const ready = () => reduce(initialSession(), { type: 'framing', framing: 'ready', captureId: 1 });

test('every label the native presentation matcher can emit reaches a confirmed caption', () => {
  const swift = readFileSync(new URL('../../ios/Signloop/BasicSignMatcher.swift', import.meta.url), 'utf8');
  const vocabulary = swift.match(/static let presentationVocabulary = \[([^\]]+)\]/)![1];
  const nativeLabels = [...vocabulary.matchAll(/"([A-Z]+)"/g)].map(match => match[1]);
  assert.deepEqual(Object.keys(signText), nativeLabels, 'JS and the actual native vocabulary must agree');
  for (const label of nativeLabels) {
    const translation = candidateFromPrediction(event(label), true, 1)!;
    assert.equal(translation.type, 'candidate', label);
    const suggested = reduce(ready(), { type: 'translation', captureId: 1, event: translation });
    assert.equal(suggested.phrases.length, 0);
    assert.equal(suggested.speech, null);
    const confirmed = reduce(suggested, { type: 'confirm-candidate', attemptId: 1 });
    assert.equal(confirmed.phrases[0].text, signText[label as keyof typeof signText]);
    assert.equal(confirmed.speech?.text, confirmed.phrases[0].text);
  }
});

test('a below-threshold ranking stays explicitly uncertain and requires user confirmation', () => {
  const translation = candidateFromPrediction(event('HELLO', false), true, 1)!;
  const suggested = reduce(ready(), { type: 'translation', captureId: 1, event: translation });
  assert.equal(suggested.candidate?.uncertain, true);
  assert.equal(suggested.phrases.length, 0);
  assert.equal(suggested.speech, null);
  assert.equal(reduce(suggested, { type: 'confirm-candidate', attemptId: 1 }).phrases[0].text, 'Hello.');
});

test('native invalidation, malformed results, and expired observations clear suggestions', () => {
  const observed = event('HELLO');
  for (const invalid of [event(null), event('UNKNOWN'), event('constructor'),
    { ...observed, engine: 'old-model' }, { ...observed, matched: undefined },
    { ...observed, observedAtMS: NaN }, { ...observed, observedAtMS: Date.now() - 2000 }]) {
    assert.deepEqual(candidateFromPrediction(invalid as SignPredictionEvent, true, 1), { type: 'clear-candidate' });
  }
  assert.equal(candidateFromPrediction(observed, false, 1), null);
  assert.equal(candidateFromPrediction(observed, true, 2), null);
});

test('an old native binary is diagnosed before trying its incompatible view', () => {
  assert.equal(cameraAvailability(null), 'camera-unavailable');
  assert.equal(cameraAvailability({}), 'camera-update-required');
  assert.equal(cameraAvailability({ recognitionVersion: 1 }), 'camera-update-required');
  assert.equal(cameraAvailability({ recognitionVersion: 2 }), 'camera-update-required');
  assert.equal(cameraAvailability({ recognitionVersion: 3 }), null);
});

test('setup failures and missing shoulders cannot leave a candidate ready to confirm', () => {
  const suggestion = reduce(ready(), { type: 'translation', captureId: 1,
    event: candidateFromPrediction(event('THANKYOU'), true, 1)! });
  const states = {
    'references-missing': 'recognizer-missing', 'references-invalid': 'recognizer-error',
    'model-missing': 'camera-model-missing', 'recognizer-loading': 'recognizer-loading',
    'body-missing': 'body-missing',
  } as const;
  for (const [status, expected] of Object.entries(states)) {
    const native = { captureId: 1, status: status as CameraStatus, handCount: 1, message: '' };
    const framing = framingFromCamera(native, true, 1)!;
    assert.equal(framing, expected);
    assert.equal(framingFromCamera(native, true, 2), null);
    const next = reduce(suggestion, { type: 'framing', captureId: 1, framing });
    assert.equal(next.candidate, null);
    assert.equal(reduce(next, { type: 'confirm-candidate', attemptId: 1 }).phrases.length, 0);
    assert.equal(reduce(next, { type: 'translation', captureId: 1,
      event: candidateFromPrediction(event('HELLO'), true, 1)! }), next);
  }
});

const rankedEvent = (attemptId = 1): SignPredictionEvent => ({
  ...event('HELLO'), attemptId,
  candidates: [{ label: 'HELLO', distance: 0.08 }, { label: 'THANKYOU', distance: 0.09 }, { label: 'PLEASE', distance: 0.11 }],
});
function offer(state = ready(), native = rankedEvent()) {
  return reduce(state, { type: 'translation', captureId: state.captureId,
    event: candidateFromPrediction(native, true, state.captureId)! });
}

test('rolling guesses are visible but cannot be confirmed, even when their match passes', () => {
  const preview = { ...rankedEvent(), phase: 'preview' as const, attemptId: null };
  const state = offer(ready(), preview);
  assert.equal(state.signPreview, 'Hello.');
  assert.equal(state.candidate, null);
  assert.equal(reduce(state, { type: 'confirm-candidate', attemptId: 1 }).phrases.length, 0);
  assert.equal(state.speech, null);
  const completed = offer(state);
  assert.equal(completed.signPreview, null);
  assert.equal(completed.candidate?.options.length, 3);
});

test('selecting the second or third choice never speaks until explicit confirmation', () => {
  for (const [label, text] of [['THANKYOU', 'Thank you.'], ['PLEASE', 'Please.']]) {
    const offered = offer();
    const selected = reduce(offered, { type: 'select-candidate', attemptId: 1, label });
    assert.equal(selected.candidate?.text, text);
    assert.equal(selected.speech, null);
    assert.equal(selected.phrases.length, 0);
    const confirmed = reduce(selected, { type: 'confirm-candidate', attemptId: 1 });
    assert.equal(confirmed.phrases[0].text, text);
    assert.equal(confirmed.speech?.text, text);
    assert.equal(offer(confirmed).candidate, null, 'replayed attempt cannot speak again');
  }
});

test('None of these dismisses the entire attempt without changing captions or starting speech', () => {
  const rejected = reduce(offer(), { type: 'reject-candidate', attemptId: 1 });
  assert.equal(rejected.candidate, null);
  assert.equal(rejected.speech, null);
  assert.deepEqual(rejected.phrases, []);
  assert.equal(offer(rejected).candidate, null);
  const next = offer(rejected, rankedEvent(2));
  assert.equal(next.candidate?.attemptId, 2, 'a newly segmented repetition remains reviewable');
});

test('live guesses and duplicate events cannot overwrite a choice or extend its review deadline', () => {
  const selected = reduce(offer(), { type: 'select-candidate', attemptId: 1, label: 'PLEASE' });
  assert.equal(offer(selected, { ...event('THANKYOU'), phase: 'preview', attemptId: null }), selected);
  assert.equal(offer(selected, { ...rankedEvent(), observedAtMS: Date.now() + 50 }), selected);
  assert.equal(reduce(selected, { type: 'select-candidate', attemptId: 1, label: 'UNKNOWN' }), selected);
});

test('late taps and expiry callbacks cannot act on a newer gesture', () => {
  const newer = offer(offer(), rankedEvent(2));
  for (const action of [
    { type: 'select-candidate', attemptId: 1, label: 'PLEASE' },
    { type: 'confirm-candidate', attemptId: 1 },
    { type: 'reject-candidate', attemptId: 1 },
    { type: 'expire-candidate', attemptId: 1 },
  ] as const) assert.equal(reduce(newer, action), newer);
  assert.equal(offer(newer, rankedEvent(1)), newer, 'out-of-order completion cannot replace a newer one');
});

test('review lasts ten seconds, then expires without speaking or accepting a stale tap', context => {
  const now = Date.now();
  context.mock.timers.enable({ apis: ['Date'], now });
  const state = offer();
  assert.equal(state.candidate!.expiresAtMS, now + SIGN_REVIEW_MS);
  context.mock.timers.tick(SIGN_REVIEW_MS - 1);
  assert.equal(reduce(state, { type: 'expire-candidate', attemptId: 1 }), state);
  context.mock.timers.tick(1);
  const expired = reduce(state, { type: 'expire-candidate', attemptId: 1 });
  assert.equal(expired.candidate, null);
  assert.equal(expired.speech, null);
  assert.equal(reduce(state, { type: 'confirm-candidate', attemptId: 1 }).phrases.length, 0);
  assert.equal(reduce(state, { type: 'select-candidate', attemptId: 1, label: 'PLEASE' }), state);
});

test('invalid ranked lists and unsegmented legacy results cannot become confirmation choices', () => {
  for (const changes of [
    { attemptId: null }, { attemptId: 0 }, { attemptId: 1.2 }, { phase: undefined },
    { candidates: [] }, { candidates: [{ label: 'HELLO', distance: NaN }] },
    { candidates: [{ label: 'HELLO', distance: -1 }] },
    { candidates: [{ label: 'HELLO', distance: 0 }, { label: 'UNKNOWN', distance: 1 }] },
    { candidates: [{ label: 'HELLO', distance: 0 }, { label: 'HELLO', distance: 1 }] },
    { candidates: [{ label: 'HELLO', distance: 1 }, { label: 'PLEASE', distance: 0 }] },
    { candidates: [{ label: 'PLEASE', distance: 0 }] },
    { candidates: Array(4).fill({ label: 'HELLO', distance: 0 }) },
  ]) {
    assert.deepEqual(candidateFromPrediction({ ...rankedEvent(), ...changes } as SignPredictionEvent, true, 1),
      { type: 'clear-candidate' });
  }
});
