import assert from 'node:assert/strict';
import { test } from 'node:test';
import { pcm16ToFloat, wavFromPcm } from '../src/voice/pcm.ts';

test('sixteen-bit pcm becomes floats between -1 and 1', () => {
  const bytes = new ArrayBuffer(4);
  const view = new DataView(bytes);
  view.setInt16(0, 32767, true);
  view.setInt16(2, -32768, true);
  const samples = pcm16ToFloat(bytes);
  assert.ok((samples[0] ?? 0) > 0.99);
  assert.equal(samples[1], -1);
});

test('wav wrapping keeps a pcm payload after the header', () => {
  const wav = wavFromPcm(new Float32Array([0, 0.5, -0.5]), 24_000);
  const header = String.fromCharCode(...new Uint8Array(wav).slice(0, 4));
  assert.equal(header, 'RIFF');
  assert.equal(wav.byteLength, 44 + 6);
});
