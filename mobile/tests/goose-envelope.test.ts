import assert from 'node:assert/strict';
import { test } from 'node:test';
import { envelopeFromPcm, levelAt } from '../src/avatar/voice/envelope.ts';

test('silence stays closed', () => {
  const envelope = envelopeFromPcm(new Float32Array(44100), 44100);
  assert.equal(levelAt(envelope, 0.2), 0);
});

test('a loud burst is near 1 and a quiet hop is 0', () => {
  const samples = new Float32Array(44100);
  for (let i = 22050; i < 22150; i += 1) samples[i] = 1;
  const envelope = envelopeFromPcm(samples, 44100);
  assert.equal(levelAt(envelope, 0.1), 0);
  assert.ok((levelAt(envelope, 0.5) ?? 0) > 0.8);
  assert.equal(levelAt(undefined, 0.2), undefined);
});

test('levels interpolate between hops', () => {
  const envelope = { hopSeconds: 1, levels: [0, 1, 0] };
  assert.equal(levelAt(envelope, 0.5), 0.5);
  assert.equal(levelAt(envelope, 3), 0);
});
