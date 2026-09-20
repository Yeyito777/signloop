import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tokens } from '../../design-system/tokens.ts';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const python = spawnSync('python3', ['--version']);

// build.py --check fails if a generated token/icon file drifted from tokens.json or icons.json,
// or if an approved text/surface pair drops below 4.5:1. Nothing else ran it, so drift went unnoticed.
test('generated design-system files are fresh and approved contrast pairs pass', { skip: python.status !== 0 && 'python3 not available' }, () => {
  const run = spawnSync('python3', ['design-system/build.py', '--check'], { cwd: root, encoding: 'utf8' });
  assert.equal(run.status, 0, `${run.stdout}\n${run.stderr}\nRun: python3 design-system/build.py`);
  assert.match(run.stdout, /Verified \d+ files/);
});

// Independent WCAG 2.x implementation (the generator has its own in Python), so a bug in either is caught.
function luminance(hex: string) {
  const [r, g, b] = [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16) / 255)
    .map(c => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}
function contrast(a: string, b: string) {
  const [low, high] = [luminance(a), luminance(b)].sort((x, y) => x - y);
  return (high + 0.05) / (low + 0.05);
}
const { text, surface, stroke } = tokens.semantic;

test('semantic text roles meet 4.5:1 on the surfaces they are approved for', () => {
  const pairs: [keyof typeof text, keyof typeof surface][] = [
    ['default', 'canvas'], ['default', 'raised'], ['secondary', 'canvas'], ['secondary', 'raised'],
    ['onPrimary', 'primary'], ['onSecondary', 'secondary'], ['success', 'success'], ['caution', 'caution'],
    ['destructive', 'raised'], ['onInverse', 'inverse'], ['onInverseSecondary', 'inverse'],
  ];
  for (const [fg, bg] of pairs) {
    const ratio = contrast(text[fg], surface[bg]);
    assert.ok(ratio >= 4.5, `text.${fg} on surface.${bg} is ${ratio.toFixed(2)}:1`);
  }
});

// WCAG 1.4.11: interactive outlines and focus indicators need 3:1 against what they sit on.
// Known gap, not asserted: stroke.focus on the coral primary surface is 2.66:1.
test('strong outlines and the focus ring meet 3:1 on the light surfaces', () => {
  for (const bg of ['canvas', 'raised'] as const) {
    assert.ok(contrast(stroke.strong, surface[bg]) >= 3, `stroke.strong on ${bg}`);
    assert.ok(contrast(stroke.focus, surface[bg]) >= 3, `stroke.focus on ${bg}`);
  }
  assert.ok(contrast(stroke.focus, surface.secondary) >= 3, 'stroke.focus on secondary');
});
