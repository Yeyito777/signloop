import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  buildSpeechRequest,
  ELEVENLABS_MODEL_ID,
  ELEVENLABS_OUTPUT_FORMAT,
  ELEVENLABS_VOICE_SETTINGS,
  seedForSpeechText,
  messageForSpeechError,
  prepareSpeechText,
  VoiceError,
} from '../src/voice/elevenlabs.ts';

test('empty or whitespace text is rejected', () => {
  assert.throws(() => prepareSpeechText(''), VoiceError);
  assert.throws(() => prepareSpeechText('   \n\t'), VoiceError);
});

test('speech text is trimmed', () => {
  assert.equal(prepareSpeechText('  hello goose  '), 'hello goose');
});

test('speech request uses the convert endpoint, key header, and turbo model', () => {
  const request = buildSpeechRequest('Hi from SignLoop.', 'goose-voice-id', 'test-key');
  assert.equal(request.url, `https://api.elevenlabs.io/v1/text-to-speech/goose-voice-id?output_format=${ELEVENLABS_OUTPUT_FORMAT}`);
  assert.equal(request.headers['xi-api-key'], 'test-key');
  assert.equal(request.headers['Content-Type'], 'application/json');
  assert.equal(request.headers.Accept, 'audio/mpeg');
  assert.deepEqual(JSON.parse(request.body), {
    text: 'Hi from SignLoop.',
    model_id: ELEVENLABS_MODEL_ID,
    seed: seedForSpeechText('Hi from SignLoop.'),
    voice_settings: ELEVENLABS_VOICE_SETTINGS,
  });
});

test('the same line always uses the same speech seed', () => {
  assert.equal(seedForSpeechText('Hello from SignLoop.'), seedForSpeechText('Hello from SignLoop.'));
  assert.notEqual(seedForSpeechText('Hello from SignLoop.'), seedForSpeechText('Goodbye from SignLoop.'));
});

test('voice ids are encoded in the request URL', () => {
  const request = buildSpeechRequest('Hi', 'id with space', 'key');
  assert.equal(request.url, `https://api.elevenlabs.io/v1/text-to-speech/id%20with%20space?output_format=${ELEVENLABS_OUTPUT_FORMAT}`);
});

test('speech errors map to short user-facing messages', () => {
  assert.match(messageForSpeechError(401, { status: 'missing_permissions', message: 'missing the permission text_to_speech' }), /text-to-speech/i);
  assert.match(messageForSpeechError(401), /key or voice id/i);
  assert.match(messageForSpeechError(403), /key or voice id/i);
  assert.match(messageForSpeechError(404), /voice id was not found/i);
  assert.match(messageForSpeechError(429), /wait/i);
  assert.match(messageForSpeechError(503), /trouble/i);
  assert.match(messageForSpeechError(400), /could not speak/i);
  assert.match(messageForSpeechError(), /network/i);
});
