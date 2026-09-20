import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const python = spawnSync('python3', ['--version']);

// build.py --check fails if a generated token/icon file drifted from tokens.json or icons.json,
// or if an approved text/surface pair drops below 4.5:1. Nothing else ran it, so drift went unnoticed.
test('generated design-system files are fresh and approved contrast pairs pass', { skip: python.status !== 0 && 'python3 not available' }, () => {
  const run = spawnSync('python3', ['design-system/build.py', '--check'], { cwd: root, encoding: 'utf8' });
  assert.equal(run.status, 0, `${run.stdout}\n${run.stderr}\nRun: python3 design-system/build.py`);
  assert.match(run.stdout, /Verified \d+ files/);
});
