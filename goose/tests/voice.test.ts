import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  buildBackendSpeechRequest,
  buildSpeechRequest,
  buildStreamSpeechRequest,
  ELEVENLABS_MODEL_ID,
  ELEVENLABS_OUTPUT_FORMAT,
  ELEVENLABS_STREAM_FORMAT,
  emotionTags,
  emotionVoice,
  parseStreamLine,
  consumeStreamObjects,
  performanceText,
  seedForSpeechText,
  messageForSpeechError,
  messageForBackendSpeechError,
  prepareSpeechText,
  VoiceError,
} from '../src/voice/elevenlabs.ts';
import { loopbackOrigin } from '../src/voice/config.ts';

test('empty or whitespace text is rejected', () => {
  assert.throws(() => prepareSpeechText(''), VoiceError);
  assert.throws(() => prepareSpeechText('   \n\t'), VoiceError);
});

test('speech text is trimmed', () => {
  assert.equal(prepareSpeechText('  hello goose  '), 'hello goose');
});

test('speech request uses timestamps, the key header, and eleven v3', () => {
  const request = buildSpeechRequest('Hi from Honk & Tell.', 'goose-voice-id', 'test-key');
  assert.equal(ELEVENLABS_MODEL_ID, 'eleven_v3');
  assert.equal(request.url, `https://api.elevenlabs.io/v1/text-to-speech/goose-voice-id/with-timestamps?output_format=${ELEVENLABS_OUTPUT_FORMAT}`);
  assert.equal(request.headers['xi-api-key'], 'test-key');
  assert.equal(request.headers['Content-Type'], 'application/json');
  assert.equal(request.headers.Accept, 'application/json');
  assert.deepEqual(JSON.parse(request.body), {
    text: performanceText('Hi from Honk & Tell.', 'neutral'),
    model_id: ELEVENLABS_MODEL_ID,
    seed: seedForSpeechText('Hi from Honk & Tell.', 'neutral'),
    voice_settings: emotionVoice.neutral,
  });
});

test('captions stay on the raw English while TTS gets audio tags', () => {
  assert.equal(prepareSpeechText('  hello goose  '), 'hello goose');
  assert.equal(performanceText('hello goose', 'joy'), '[happily] [excited] hello goose');
  assert.equal(performanceText('hello goose', 'sadness'), '[sad] [sighs] [slowly] hello goose');
  assert.equal(performanceText('hello goose', 'anger'), '[angry] hello goose');
  assert.equal(performanceText('hello goose', 'fear'), '[worried] [nervously] hello goose');
  for (const tags of Object.values(emotionTags)) {
    for (const tag of tags) {
      assert.equal(/^(hello|back|you|me|there)$/.test(tag), false);
    }
  }
});

test('the same line and emotion always uses the same speech seed', () => {
  assert.equal(seedForSpeechText('Hello from Honk & Tell.', 'joy'), seedForSpeechText('Hello from Honk & Tell.', 'joy'));
  assert.notEqual(seedForSpeechText('Hello from Honk & Tell.', 'joy'), seedForSpeechText('Hello from Honk & Tell.', 'sadness'));
});

test('each emotion sends different voice settings and tagged text', () => {
  const joy = JSON.parse(buildSpeechRequest('Hi', 'id', 'key', 'joy').body);
  const sad = JSON.parse(buildSpeechRequest('Hi', 'id', 'key', 'sadness').body);
  const anger = JSON.parse(buildSpeechRequest('Hi', 'id', 'key', 'anger').body);
  const fear = JSON.parse(buildSpeechRequest('Hi', 'id', 'key', 'fear').body);
  assert.deepEqual(joy.voice_settings, emotionVoice.joy);
  assert.deepEqual(sad.voice_settings, emotionVoice.sadness);
  assert.notDeepEqual(joy.voice_settings, sad.voice_settings);
  assert.notDeepEqual(joy.voice_settings, anger.voice_settings);
  assert.notDeepEqual(joy.voice_settings, fear.voice_settings);
  assert.equal(joy.text, performanceText('Hi', 'joy'));
  assert.equal(sad.text, performanceText('Hi', 'sadness'));
  assert.notEqual(joy.text, sad.text);
  assert.notEqual(anger.text, fear.text);
});

test('voice ids are encoded in the request URL', () => {
  const request = buildSpeechRequest('Hi', 'id with space', 'key');
  assert.equal(request.url, `https://api.elevenlabs.io/v1/text-to-speech/id%20with%20space/with-timestamps?output_format=${ELEVENLABS_OUTPUT_FORMAT}`);
});

test('a ready phrase streams pcm with timestamps', () => {
  const request = buildStreamSpeechRequest('hello it is me', 'goose-voice-id', 'test-key', 'joy');
  assert.equal(request.url, `https://api.elevenlabs.io/v1/text-to-speech/goose-voice-id/stream/with-timestamps?output_format=${ELEVENLABS_STREAM_FORMAT}`);
  assert.equal(JSON.parse(request.body).text, performanceText('hello it is me', 'joy'));
  assert.equal(JSON.parse(request.body).model_id, ELEVENLABS_MODEL_ID);
});

test('stream lines tolerate a data prefix and skip blanks', () => {
  assert.equal(parseStreamLine(''), undefined);
  assert.equal(parseStreamLine('data: [DONE]'), undefined);
  assert.deepEqual(parseStreamLine('data: {"audio_base64":"QQ=="}'), { audio_base64: 'QQ==' });
});

test('pretty-printed stream objects still parse', () => {
  const { objects, rest } = consumeStreamObjects('{\n  "audio_base64": "QQ=="\n}\n{ "audio_base64": "Qg==" } leftover');
  assert.equal(objects.length, 2);
  assert.equal(objects[0]?.audio_base64, 'QQ==');
  assert.equal(objects[1]?.audio_base64, 'Qg==');
  assert.equal(rest, '');
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

test('backend speech stays on loopback and never sends the provider key', () => {
  const request = buildBackendSpeechRequest('  Hello goose  ', 'http://127.0.0.1:8787', 'local-backend-token-24chars', 'joy');
  assert.equal(request.url, 'http://127.0.0.1:8787/v1/speech');
  assert.equal(request.headers.Authorization, 'Bearer local-backend-token-24chars');
  assert.equal(request.headers['Content-Type'], 'application/json');
  assert.equal(JSON.parse(request.body).text, 'Hello goose');
  assert.equal(JSON.parse(request.body).emotion, 'joy');
  assert.equal('xi-api-key' in request.headers, false);
  assert.equal(loopbackOrigin('http://127.0.0.1:8787/'), 'http://127.0.0.1:8787');
  assert.equal(loopbackOrigin('http://localhost:8787'), 'http://localhost:8787');
  assert.equal(loopbackOrigin('https://example.com'), '');
  assert.equal(loopbackOrigin('http://127.0.0.1:8787/v1/speech'), '');
  assert.match(messageForBackendSpeechError(401), /backend access token/i);
  assert.match(messageForBackendSpeechError(503), /not configured/i);
  assert.match(messageForBackendSpeechError(), /port 8787/i);
});
