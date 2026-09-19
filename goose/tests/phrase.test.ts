import assert from 'node:assert/strict';
import { test } from 'node:test';
import { englishWhenReady } from '../src/voice/phrase.ts';
import { VoiceError } from '../src/voice/elevenlabs.ts';

test('drafts do not become English until the phrase is ready', () => {
  assert.equal(englishWhenReady({ text: 'hello it is me', emotion: 'joy', ready: false }), null);
  assert.equal(englishWhenReady({ text: '', emotion: 'sadness', ready: false }), null);
});

test('a ready phrase is the trimmed English teammates sent', () => {
  assert.equal(englishWhenReady({ text: '  hello it is me  ', emotion: 'joy', ready: true }), 'hello it is me');
});

test('ready with nothing to say is rejected', () => {
  assert.throws(() => englishWhenReady({ text: '   ', emotion: 'anger', ready: true }), VoiceError);
});
