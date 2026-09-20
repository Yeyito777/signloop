# Presentation-only vocabulary — build 17

The user requested removing every word outside the presentation script, retaining
I LOVE YOU. The standalone scanner now searches exactly:

**HELLO, MY, NAME, TODAY, WE, SHOW, PHONE, PLEASE, SORRY, THANKYOU, ILOVEYOU.**

This matches the last tutorial:

1. HELLO → MY → NAME; separately fingerspell AURELIO.
2. TODAY → WE → SHOW; separately fingerspell SIGNLOOP.
3. MY / PLEASE / SORRY movement contrast, then PHONE.
4. THANK YOU → I LOVE YOU.

These are demo segments, not automatic sentence transcription or an assertion
of fluent ASL grammar. Signs mode still displays a single experimental best guess.
The separate 24-static-letter spelling mode and explicit manual J/Z entry remain
unchanged; letters do not compete with word signs.

## Actual search restriction, not a display filter

`ContentView` explicitly requests `BasicSignScore.presentationVocabulary` from
`BasicLiveRecognition`. The adapter validates the original private bank, then
constructs a restricted bank **before** initializing `BasicSignMatcher`.
Only the 56 training references belonging to these 11 words enter the live search,
instead of 165 for 32 words. Excluded signs cannot appear as winners or score rows.
Startup, reset and missing-tracking states also keep the 11-word list.

The original private bank on the phone and Mac is retained for reversibility,
not deleted or redistributed. Existing build-15/16 provisioning remains compatible;
no new reference download or copy is needed. No API, recording or upload is added.
An incompatible bank fails unavailable rather than silently re-enabling all words.

Restriction preserves window duration, rule weight, distance thresholds and every
remaining label's absolute distance. Schema validation permits 2–32 labels for
native restricted banks, still enforcing unique labels, train-only references,
valid geometry and resource limits. Private backend provisioning continues to
validate the original source corpus, not fabricate a new corpus for this subset.

## Checks

- 72 synthetic matcher/real asynchronous adapter invariants passed: even a
  former exact winning reference cannot win after exclusion; remaining distances
  are identical; malformed subsets and filtering to conceal invalid input fail.
- 74 existing validation clips replayed with the same native restriction:
  7,568 retained-label score entries exactly match the 32-word baseline.
  No excluded label was emitted. No threshold was tuned.
- Descriptive development result: most-frequent guess correct in 17/22 clips for
  the 11 active signs (19/22 had guesses). This is a small, already-inspected
  cohort, not live-phone or fresh held-out-signer accuracy.
- 48 of the 52 now-unsupported validation clips still get some active-word guess:
  restricting vocabulary is **not** reliable unknown-sign rejection.
- Full core suite and 13 simulator UI tests passed. The real 32-word private
  bank loaded in the simulator with **All 11** / **11-sign research preview**;
  no camera evidence correctly remained Watching. No synthetic live sign shown.
- Release build 17 signed and signature-verified; app/source credential scan
  passed and private references remain outside the app bundle.
- Installed on Yeyito on September 19 at 21:03. Launch was blocked only by the
  phone's lock screen; unlock/open Signloop to run the restricted scanner.

Reproduce the native restriction using the retained private inputs:

```sh
mkdir -p .runtime
swiftc -O -parse-as-library ios/Signloop/Skeleton.swift \
  ios/Signloop/BasicSignMatcher.swift ios/Tests/BasicSignReplay.swift \
  -o .runtime/replay
.runtime/replay ../vocabulary-32/.runtime/demo-live/basic-references-packed.json \
  ../vocabulary-32/.runtime/demo-live/val.json .runtime/presentation-val.json \
  --presentation --scores
```
