import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { AbortController as RNAbortController } from 'abort-controller';
import { translationFromPrediction } from '../src/integrations/localSign.ts';
import { initialSession, sessionReducer as reduce } from '../src/session/model.ts';
import { captionPresentation } from '../src/session/captionPresentation.ts';
import { backendOrigin, disableVoiceUploads, getVoiceSettings, setVoiceSettings } from '../src/integrations/voiceSettings.ts';
import { fetchSpeech, validateAlignment } from '../src/integrations/speechTransport.ts';
import { createVoiceAdapter } from '../src/integrations/voiceLifecycle.ts';
import { claimLipSync, gooseLipSync } from '../src/integrations/lipSync.ts';

const configured = { url: 'https://voice.example.test', token: 'test-only-backend-token-24-characters', enabled: true };
const clip = { audio_base64: 'SUQz', alignment: {
  characters: ['h', 'i'], character_start_times_seconds: [0, 0.1], character_end_times_seconds: [0.1, 0.2],
} };
afterEach(() => setVoiceSettings({ url: '', token: '', enabled: false }));
function ready() { return reduce(initialSession(), { type: 'framing', captureId: 1, framing: 'ready' }); }
function prediction(attemptId = 1, phase: 'preview' | 'completed' = 'completed') {
  return translationFromPrediction({ engine: 'basic-temporal-v3', phase, attemptId, candidates: [{ label: 'ILOVEYOU', distance: 0.1 }], matched: true, captureId: 1, label: 'ILOVEYOU', observedAtMS: Date.now() }, true, 1)!;
}

test('native temporal prediction → backend audio → playback', async () => {
  setVoiceSettings(configured);
  let state = reduce(ready(), { type: 'translation', captureId: 1, event: prediction() });
  assert.equal(state.phrases[0].text, 'I love you.');
  assert.equal(captionPresentation(state, 'live').delivery, 'Preparing voice…');
  let requests = 0;
  const request: typeof fetch = async (url, init) => {
    requests++;
    assert.equal(url, 'https://voice.example.test/v1/speech');
    assert.equal(new Headers(init?.headers).get('Authorization'), `Bearer ${configured.token}`);
    assert.equal(new Headers(init?.headers).has('xi-api-key'), false);
    assert.equal(init?.redirect, 'error');
    assert.deepEqual(JSON.parse(String(init?.body)), { text: 'I love you.', emotion: 'neutral' });
    return Response.json(clip);
  };
  const voice = createVoiceAdapter(
    (text, prefs, signal) => fetchSpeech(text, prefs, signal, request),
    async (result, _signal, onStart) => { assert.deepEqual([...result.audio], [73, 68, 51]); onStart?.(); },
  );
  const speech = state.speech!;
  await voice.speak(speech, new AbortController().signal, () => {
    state = reduce(state, { type: 'speech-started', id: speech.id });
    assert.equal(captionPresentation(state, 'live').delivery, 'Speaking');
  });
  state = reduce(state, { type: 'speech-ended', id: speech.id });
  assert.equal(requests, 1);
  assert.equal(state.phrases[0].status, 'played');
});

test('unknown, stale, future and wrong-generation observations cannot produce accepted words', () => {
  const now = Date.now();
  for (const label of ['Thumb_Up', 'I_LOVE_YOU', '', 'UNKNOWN', 'toString']) {
    assert.deepEqual(translationFromPrediction({ engine: 'basic-temporal-v3', phase: 'completed', attemptId: 1, candidates: [{ label: 'ILOVEYOU', distance: 0.1 }], matched: true, captureId: 1, label, observedAtMS: now }, true, 1), { type: 'clear-preview' });
  }
  assert.equal(translationFromPrediction({ engine: 'basic-temporal-v3', phase: 'completed', attemptId: 1, candidates: [{ label: 'ILOVEYOU', distance: 0.1 }], matched: true, captureId: 0, label: 'ILOVEYOU', observedAtMS: now }, true, 1), null);
  assert.equal(translationFromPrediction({ engine: 'basic-temporal-v3', phase: 'completed', attemptId: 1, candidates: [{ label: 'ILOVEYOU', distance: 0.1 }], matched: true, captureId: 1, label: 'ILOVEYOU', observedAtMS: now }, false, 1), null);
  for (const time of [now - 2000, now + 2000, NaN]) {
    assert.deepEqual(translationFromPrediction({ engine: 'basic-temporal-v3', phase: 'completed', attemptId: 1, candidates: [{ label: 'ILOVEYOU', distance: 0.1 }], matched: true, captureId: 1, label: 'ILOVEYOU', observedAtMS: time }, true, 1), { type: 'clear-preview' });
  }
});

test('holding a completed sign does not repeat it; a new gesture speaks the next word', () => {
  let state = reduce(ready(), { type: 'translation', captureId: 1, event: prediction() });
  state = reduce(state, { type: 'translation', captureId: 1, event: prediction() });
  assert.equal(state.signPreview, null);
  assert.equal(state.phrases.length, 1);
  state = reduce(state, { type: 'translation', captureId: 1, event: { type: 'clear-preview' } });
  state = reduce(state, { type: 'translation', captureId: 1, event: prediction(2) });
  assert.equal(state.phrases.length, 2);
  assert.equal(state.speech?.text, 'I love you.');
  assert.equal(state.speechQueue.length, 1);
});

test('pause, sheets and framing loss invalidate previews and late completed signs', () => {
  const state = reduce(ready(), { type: 'translation', captureId: 1, event: prediction(1, 'preview') });
  for (const action of [
    { type: 'pause' } as const,
    { type: 'open-sheet', sheet: 'menu' } as const,
    { type: 'framing', framing: 'hands-missing', captureId: 1 } as const,
  ]) {
    const next = reduce(state, action);
    assert.equal(next.signPreview, null);
    assert.equal(next.phrases.length, 0);
    assert.equal(reduce(next, { type: 'translation', captureId: 1, event: prediction() }), next);
  }
});

test('captions-only mode saves the phrase without any voice request', () => {
  const state = reduce({ ...ready(), muted: true }, { type: 'translation', captureId: 1, event: prediction() });
  assert.equal(state.phrases.length, 1);
  assert.equal(state.speech, null);
});

test('an accepted result clears the previous live guess', () => {
  let state = reduce(ready(), { type: 'translation', captureId: 1, event: prediction(1, 'preview') });
  state = reduce(state, { type: 'translation', captureId: 1,
    event: { type: 'accepted', id: 'explicit', text: 'I love you.', emotion: 'neutral' } });
  assert.equal(state.signPreview, null);
  assert.equal(state.phrases.length, 1);
});

test('older playback cleanup cannot reset the lip-sync clock of its replacement', () => {
  const first = claimLipSync({ currentTime: () => 1 });
  const second = claimLipSync({ currentTime: () => 2 });
  first();
  assert.equal(gooseLipSync.current.currentTime(), 2);
  second();
  assert.equal(gooseLipSync.current.currentTime(), 0);
});

test('backend URLs reject credentials, public cleartext, paths and unsupported protocols', () => {
  for (const url of ['file:///secret', 'http://example.com', 'https://u:p@example.com',
    'https://example.com/?token=secret', 'https://example.com/api', 'https://example.com/#secret',
    'http://10.1.2.999', 'http://10.1.2.3.attacker.test', 'http://172.32.1.2']) {
    assert.throws(() => backendOrigin(url));
  }
  for (const url of ['https://example.com', 'http://localhost:8787', 'http://192.168.1.5:8787',
    'http://10.0.0.5', 'http://172.16.0.3', 'http://mac.local:8787']) {
    assert.equal(backendOrigin(url), url);
  }
});

test('no consent, missing token and aborted requests make no network call (RN polyfill supported)', async () => {
  let calls = 0;
  const request: typeof fetch = async () => { calls++; return Response.json(clip); };
  const signal = new RNAbortController().signal as unknown as AbortSignal;
  assert.equal((signal as { throwIfAborted?: unknown }).throwIfAborted, undefined);
  await assert.rejects(fetchSpeech({ text: 'hello', emotion: 'neutral' }, { ...configured, enabled: false }, signal, request), /Enable/);
  await assert.rejects(fetchSpeech({ text: 'hello', emotion: 'neutral' }, { ...configured, token: '' }, signal, request), /token/);
  await assert.rejects(fetchSpeech({ text: ' '.repeat(501), emotion: 'neutral' }, configured, signal, request), /characters/);
  const abort = new RNAbortController();
  abort.abort();
  await assert.rejects(fetchSpeech({ text: 'hello', emotion: 'neutral' }, configured, abort.signal as unknown as AbortSignal, request), /cancelled/);
  await assert.rejects(fetchSpeech({ text: 'hello', emotion: 'neutral' }, configured, signal,
    async () => { throw new TypeError('Network request failed'); }), /Could not reach the backend/);
  assert.equal(calls, 0);
  assert.deepEqual([...(await fetchSpeech({ text: 'hello', emotion: 'neutral' }, configured, signal, request)).audio], [73, 68, 51]);
});

test('voice response errors never leak backend bodies and malformed audio is rejected', async () => {
  for (const status of [401, 429, 503]) {
    await assert.rejects(fetchSpeech({ text: 'hello', emotion: 'neutral' }, configured, new AbortController().signal,
      async () => new Response('SENSITIVE BODY', { status })), error => !String(error).includes('SENSITIVE BODY'));
  }
  for (const audio_base64 of ['', '@@@@', 'a', 123]) {
    await assert.rejects(fetchSpeech({ text: 'hello', emotion: 'neutral' }, configured, new AbortController().signal,
      async () => Response.json({ audio_base64 })), /Invalid voice/);
  }
  await assert.rejects(fetchSpeech({ text: 'hello', emotion: 'neutral' }, configured, new AbortController().signal,
    async () => Response.json(clip, { headers: { 'content-length': '99999999' } })), /too large/);
  assert.equal(validateAlignment({ ...clip.alignment, character_start_times_seconds: [1, 0] }), undefined);
});

test('cancel during fetch discards late audio instead of playing it', async () => {
  setVoiceSettings(configured);
  let complete!: (clip: { audio: Uint8Array }) => void;
  let played = false;
  const adapter = createVoiceAdapter(async () => new Promise(resolve => { complete = resolve; }),
    async () => { played = true; });
  const controller = new AbortController();
  const result = adapter.speak({ text: 'hello', emotion: 'neutral' }, controller.signal);
  controller.abort();
  complete({ audio: new Uint8Array([1]) });
  await assert.rejects(result, /cancelled/);
  assert.equal(played, false);
});

test('revoking consent cancels active playback and cannot mark a stopped phrase as spoken', async () => {
  setVoiceSettings(configured);
  let playing!: () => void;
  const entered = new Promise<void>(resolve => { playing = resolve; });
  const adapter = createVoiceAdapter(async () => ({ audio: new Uint8Array([1]) }),
    async (_clip, signal) => new Promise<void>((_resolve, reject) => {
      signal.addEventListener('abort', () => reject(new Error('cancelled')), { once: true });
      playing();
    }));
  const result = adapter.speak({ text: 'hello', emotion: 'neutral' }, new AbortController().signal);
  await entered;
  disableVoiceUploads();
  await assert.rejects(result, /cancelled/);
  assert.equal(getVoiceSettings().enabled, false);
  const state = reduce(reduce(ready(), { type: 'translation', captureId: 1,
    event: { type: 'accepted', id: 'test', text: 'hello', emotion: 'neutral' } }), { type: 'disable-voice' });
  assert.equal(state.speech, null);
  assert.equal(state.phrases[0].status, 'interrupted');
});
