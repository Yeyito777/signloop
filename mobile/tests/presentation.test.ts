import test from 'node:test';
import assert from 'node:assert/strict';
import { createFramingFeedback } from '../src/session/framingFeedback.ts';
import { captionPresentation } from '../src/session/captionPresentation.ts';
import { initialSession, sessionReducer as reduce } from '../src/session/model.ts';
import type { Framing } from '../src/integrations/contracts.ts';

function accepted() {
  const state = reduce(initialSession(), { type: 'framing', framing: 'ready', captureId: 1 });
  return reduce(state, { type: 'translation', captureId: state.captureId, event: { type: 'accepted', id: 'one', text: 'Could we sit by the window?', emotion: 'neutral' } });
}

test('brief tracking loss does not flicker the visual readiness state', context => {
  context.mock.timers.enable({ apis: ['setTimeout'] });
  const seen: Framing[] = [];
  const feedback = createFramingFeedback(value => seen.push(value));
  feedback.update('ready', true);
  context.mock.timers.tick(299);
  assert.deepEqual(seen, []);
  context.mock.timers.tick(1);
  feedback.update('hands-missing', true);
  context.mock.timers.tick(200);
  feedback.update('ready', true);
  context.mock.timers.tick(500);
  assert.deepEqual(seen, ['ready']);
  feedback.update('hands-missing', true);
  context.mock.timers.tick(450);
  assert.deepEqual(seen, ['ready', 'hands-missing']);
  feedback.dispose();
});

test('permission failures are immediate and suspended feedback cannot publish stale success', context => {
  context.mock.timers.enable({ apis: ['setTimeout'] });
  const seen: Framing[] = [];
  const feedback = createFramingFeedback(value => seen.push(value));
  feedback.update('ready', true);
  feedback.update('camera-denied', true);
  assert.deepEqual(seen, ['camera-denied']);
  context.mock.timers.tick(1000);
  assert.deepEqual(seen, ['camera-denied']);
  feedback.reset();
  feedback.update('ready', true);
  feedback.update('ready', false);
  context.mock.timers.tick(1000);
  assert.deepEqual(seen, ['camera-denied', 'finding']);
  feedback.update('ready', true);
  feedback.dispose();
  context.mock.timers.tick(1000);
  assert.equal(seen.at(-1), 'finding');
});

test('accepted words survive the next draft, framing loss, uncertainty and connection errors', () => {
  const state = accepted();
  for (const event of [{ type: 'draft', text: 'A different sentence…' }, { type: 'thinking' }, { type: 'uncertain' }, { type: 'offline' }] as const) {
    const next = reduce(state, { type: 'translation', captureId: state.captureId, event });
    assert.equal(captionPresentation(next, 'live').text, 'Could we sit by the window?');
  }
  const lost = reduce(state, { type: 'framing', framing: 'hands-missing', captureId: state.captureId });
  assert.equal(captionPresentation(lost, 'live').text, 'Could we sit by the window?');
});

test('drafts are visibly unspoken, while queue and demo states cannot claim completed speech', () => {
  const ready = reduce(initialSession(), { type: 'framing', framing: 'ready', captureId: 1 });
  const draft = reduce(ready, { type: 'translation', captureId: 1, event: { type: 'draft', text: 'Could we…' } });
  assert.equal(captionPresentation(draft, 'live').label, 'Draft · not spoken');
  assert.equal(captionPresentation(draft, 'live').delivery, '');
  const guess = reduce(ready, { type: 'translation', captureId: 1, event: { type: 'sign-preview', text: 'Hello.', attemptId: 1, observedAtMS: Date.now() } });
  assert.equal(captionPresentation(guess, 'live').text, 'Hello.');
  assert.equal(captionPresentation(guess, 'live').label, 'Reading…');
  const state = accepted();
  assert.equal(captionPresentation(state, 'live').label, 'Preparing voice…');
  assert.equal(captionPresentation(state, 'live').delivery, 'Preparing voice…');
  const nextGuess = reduce(state, { type: 'translation', captureId: state.captureId, event: { type: 'sign-preview', text: 'Hello.', attemptId: 2, observedAtMS: Date.now() } });
  assert.equal(captionPresentation(nextGuess, 'live').text, 'Could we sit by the window?');
  assert.equal(captionPresentation(nextGuess, 'live').preview, 'Hello.');
  assert.equal(captionPresentation(nextGuess, 'live').delivery, 'Preparing voice…');
  const queued = reduce(state, { type: 'translation', captureId: state.captureId, event: { type: 'accepted', id: 'two', text: 'Thank you.', emotion: 'neutral' } });
  assert.equal(captionPresentation(queued, 'live').delivery, 'Waiting to speak');
  assert.equal(captionPresentation(state, 'demo').delivery, 'Playing · silent preview');
  const finished = reduce(state, { type: 'speech-ended', id: state.speech!.id });
  assert.equal(captionPresentation(finished, 'live').delivery, 'Spoken');
  assert.equal(captionPresentation(finished, 'demo').delivery, 'Preview finished');
});
