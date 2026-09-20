/** Replay automatic best-match captions through the real JS adapter and
 * session reducer. Input contains rankings/times, never images or landmarks.
 * Run with Node: node --experimental-strip-types scripts/replay-sign-reviews.ts
 * ../.runtime/gesture-experiments/revised.json
 */
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
import { translationFromPrediction, signText } from '../src/integrations/localSign.ts';
import { initialSession, sessionReducer } from '../src/session/model.ts';

const file = process.argv[2];
const report = JSON.parse(readFileSync(file, 'utf8'));
const summary = JSON.parse(readFileSync(file.replace(/\.json$/, '.summary.json'), 'utf8'));
const names = Object.keys(signText);
const canonical = (label: string): string => names[report.labels.indexOf(label)];
const realNow = Date.now;
let known = 0, captioned = 0, correct = 0;
try {
  for (const row of report.rows) {
    if (row.policy !== 'hybrid' || row.repetition !== 0 || row.endMS === undefined
      || !report.labels.includes(row.label)) continue;
    known++;
    let state = sessionReducer(initialSession(), { type: 'framing', captureId: 1, framing: 'ready' });
    for (const event of row.events) {
      if (event.readyMS > row.endMS + 600) break;
      Date.now = () => 1_000_000 + event.readyMS;
      const translation = translationFromPrediction({
        engine: 'basic-temporal-v3', captureId: 1, phase: event.phase,
        observedAtMS: 1_000_000 + event.observedMS, matched: false,
        attemptId: event.attemptID ?? null,
        label: event.choices.length ? canonical(event.choices[0]) : null,
        candidates: event.choices.map((label: string, index: number) => ({ label: canonical(label), distance: index * 0.1 })),
      }, true, 1);
      if (translation) state = sessionReducer(state, { type: 'translation', event: translation, captureId: 1 });
      assert.equal(new Set(state.phrases.map(phrase => phrase.id)).size, state.phrases.length,
        'a completed attempt must never be added twice');
    }
    captioned += Number(state.phrases.length > 0);
    correct += Number(state.phrases.at(-1)?.text === signText[canonical(row.label) as keyof typeof signText]);
  }
} finally { Date.now = realNow; }
assert.equal(known, summary.summaries['all/hybrid'].known);
console.log(`Automatic captions at deadline: ${captioned}/${known} captioned, ${correct}/${known} correct best matches. Historical top-three review scores are not comparable.`);
