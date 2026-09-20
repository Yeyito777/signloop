import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { decodeShellScript } = require('../plugins/with-quoted-bundle-path.cjs');
test('prebuild accepts both disk-escaped and Expo in-memory shell scripts', () => {
  const script = 'echo "a path with spaces"\n\techo done\n';
  assert.equal(decodeShellScript(JSON.stringify(script)), script);
  assert.equal(decodeShellScript(JSON.stringify(script).replace(/\\n/g, '\n').replace(/\\t/g, '\t')), script);
  assert.equal(decodeShellScript(script), script);
});
