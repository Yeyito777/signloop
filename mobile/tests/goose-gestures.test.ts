import assert from 'node:assert/strict';
import { test } from 'node:test';
import { alignmentWithoutAudioTags, cuesFromText, cuesFromWords, gestureAt, wordsFromAlignment } from '../src/avatar/voice/gestures.ts';

test('audio tags are stripped before word matching', () => {
  const cleaned = alignmentWithoutAudioTags({
    characters: ['[', 'y', 'o', 'u', ']', ' ', 'h', 'e', 'l', 'l', 'o', ' ', '[happily]', 't', 'h', 'e', 'r', 'e'],
    character_start_times_seconds: [0, 0.01, 0.02, 0.03, 0.04, 0.05, 0.1, 0.12, 0.14, 0.16, 0.18, 0.2, 0.21, 0.3, 0.32, 0.34, 0.36, 0.38],
    character_end_times_seconds: [0.01, 0.02, 0.03, 0.04, 0.05, 0.1, 0.12, 0.14, 0.16, 0.18, 0.2, 0.21, 0.3, 0.32, 0.34, 0.36, 0.38, 0.4],
  });
  const words = wordsFromAlignment(cleaned);
  assert.deepEqual(words.map(word => word.word), ['hello', 'there']);
  assert.equal(words[0]?.start, 0.1);
});

test('alignment characters group into timed words', () => {
  const words = wordsFromAlignment({
    characters: ['H', 'e', 'l', 'l', 'o', ' ', 't', 'h', 'e', 'r', 'e', '!'],
    character_start_times_seconds: [0, 0.05, 0.1, 0.15, 0.2, 0.28, 0.32, 0.36, 0.4, 0.45, 0.5, 0.55],
    character_end_times_seconds: [0.05, 0.1, 0.15, 0.2, 0.28, 0.32, 0.36, 0.4, 0.45, 0.5, 0.55, 0.58],
  });
  assert.deepEqual(words.map(word => word.word), ['hello', 'there']);
  assert.equal(words[0]?.start, 0);
  assert.equal(words[1]?.start, 0.32);
});

test('only the tiny gesture list becomes cues', () => {
  const cues = cuesFromWords([
    { word: 'hello', start: 0.1, end: 0.4 },
    { word: 'your', start: 0.5, end: 0.7 },
    { word: 'you', start: 0.8, end: 1 },
    { word: 'friend', start: 1.1, end: 1.4 },
  ], 0.9);
  assert.deepEqual(cues.map(cue => cue.name), ['hello', 'you']);
  assert.equal(cues[0]?.start, 0.1);
  assert.equal(cues[0]?.end, 1);
});

test('text fallback keeps word order and skips the rest', () => {
  const cues = cuesFromText('Hello there, my friend', 0.9);
  assert.deepEqual(cues.map(cue => cue.name), ['hello', 'there']);
  assert.equal(cues[1]?.start, 0.9);
});

test('gestureAt follows the word clock', () => {
  const cues = cuesFromText('hello there', 1);
  assert.equal(gestureAt(cues, 0.2)?.name, 'hello');
  assert.equal(gestureAt(cues, 1.2)?.name, 'there');
  assert.equal(gestureAt(cues, 3), undefined);
});
