# AURELIO-only spelling and smaller WE movements — build 18

## Seven active letters

The user requested removing C, P and every letter outside AURELIO. The native
scanner now selects only **A, U, R, E, L, I, O**. This is a restriction of the
existing attributed model, not retraining or an assertion that other handshapes
are unknown. Unsupported handshapes may still receive an allowed-letter guess.

Selection occurs on the seven active **logits before softmax**, not by hiding
unwanted guesses afterward. An excluded C/P cannot win or underflow all active
scores to zero. The original full output weights are retained unchanged for
reversibility and parity; they do not participate in active winner selection.

The RAM-only draft and explicit manual menu accept only the same seven letters.
J/Z, space and other manual entries are removed. Every recognized letter still
requires **Add**. No automatic text, autocorrect or hidden letter sequence is used.
**SIGNLOOP can no longer be spelled in this restricted mode.**

On the existing source samples for these letters, full-alphabet top-1 was
357/362; restricted selection is **362/362**. All 936 source examples produce
only allowed letters in restricted mode. This is **not 100% live accuracy**:
the source has no signer/session IDs and has been inspected previously.
Original full-model parity remains 936/936 identical top labels, maximum score
difference approximately `6.3e-7`. The 2,839 native alphabet checks include
actual async adapter behavior, draft rejection, invalid whitelists and a
synthetic extreme excluded-logit test.

## WE: tolerate smaller movement, not a different sign

Keep the real index-finger handshape and arc across the upper chest. The app
adds one smaller-motion variant to each of the **six existing training WE
references**:

- Wrist/elbow excursion around their original temporal centers is scaled to
  **65%**; corresponding motion channels are scaled consistently.
- Observed hand-local XYZ, handshape, orientation, timing, missing observations
  and the original reference remain unchanged.
- Other labels' templates, scores and thresholds are unchanged.
- The extra variant is available only for an index-dominant handshape moving
  horizontally in the upper-chest region. Fingers may be relaxed, but the index
  must be straighter than the other fingers. A stationary point, low hand, or
  NAME-like two-finger shape does not unlock this tolerance. The wrist need not
  cross the shoulder midpoint: the pointing fingertip may cross while the wrist
  stays on one side. Original WE matching is never gated.
- This produces 62 cached templates from 56 original private training examples,
  not six new human-labeled examples. It is standard geometry augmentation,
  not hand-invented reference handshapes or relabeled unrelated signs.

Source banks remain private and unchanged. The runtime policy is explicit in
`BasicLiveRecognition`/`BasicSignMatcher`; `packedBank` never serializes generated
variants under invented source provenance. Existing phone reference provisioning
remains compatible. Nothing is recorded or uploaded.

### Initial ungated experiment — not the shipped policy

Compared baseline, scale 0.8 and scale 0.65 using training-signer leave-one-out
folds and the existing validation cohort only:

| Check | Baseline | 0.8 | Selected 0.65 |
|---|---:|---:|---:|
| Natural WE train-signer folds, majority correct | 4/6 | 5/6 | 6/6 |
| Derived smaller-motion stress clips, majority correct | 4/6 | 5/6 | 5/6 |
| All active-sign validation clips, majority correct | 17/22 | 17/22 | 17/22 |
| Validation clips with false WE guesses | 7 | 7 | 7 |
| Validation windows with false WE guesses | 22 | 23 | 24 |

All references from the evaluated training signer are removed in each fold,
including their other signs. Stress clips are synthetic transformations of
actual training clips, **not additional real ASL accuracy evidence**. The small
validation WE cohort is tracking-limited: one clip offers only one measurable
window; the other offers none. No new validation clip becomes incorrect, but
there are two extra false WE windows inside already-confused clips.

This makes movement size less rigid; it does not establish live accuracy or
solve missing hand observations. Keep the hand visible and try a relaxed arc,
not an exaggerated sweep. Do not substitute a different gesture and call it WE.

### Safety revision and final evidence

A subsequent diagnostic on the already-inspected test cohort exposed extra WE
guesses during YES, HELP and NAME in the ungated prototype. It was not shipped.
The anatomical/location/movement guard above was added during development;
these reused cohorts are **not fresh blind tests**.

The final guarded 0.65 variant:

- Natural training-signer folds: 4/6 majority correct, unchanged; correctly
  labeled WE windows **18 → 20**.
- Smaller-motion stress clips: 4/6 majority correct, unchanged; WE windows
  **18 → 19**.
- Validation: 17/22 active-sign clips correct, unchanged; false WE **7 clips /
  22 windows**, unchanged.
- Existing test replay: 24/33 active-sign clips correct and WE 1/3, unchanged.
  False WE **6 clips / 30 windows**, unchanged.
- Every non-WE absolute score remains identical across the 106 test clips.
- 90 native matcher invariants passed, including the guard, amplitude/shape
  preservation, missing evidence, invalid scales, same-side wrist arcs and
  unaffected other-label scores. The full core suite and five Python audit
  tests also passed.

This adds limited movement-size tolerance and slightly improves WE continuity
in development replays; **it has not demonstrated better per-clip WE accuracy or
live-phone accuracy**. The broader ungated recall improvement above must not be
attributed to the final guarded build.

Final release build 18 and signature verification passed. All 13 final simulator
UI tests passed, including the restricted manual menu, draft persistence rules
and large-text controls. Source/app secret scans passed; the private word bank
and attributed alphabet weights are unchanged and no private bank is bundled.
Installation was attempted September 19 at approximately 21:52, but CoreDevice
could not locate Yeyito. **Build 18 was not installed in that attempt.**

Reproduce privately:

```sh
mkdir -p .runtime
swiftc -O -parse-as-library ios/Signloop/Skeleton.swift \
  ios/Signloop/BasicSignMatcher.swift ios/Tests/BasicSignReplay.swift \
  -o .runtime/replay
python3 -m backend.we_motion_audit --replay .runtime/replay \
  --bank ../vocabulary-32/.runtime/demo-live/basic-references-packed.json \
  --raw-bank ../vocabulary-32/.runtime/demo-live/basic-references.json \
  --validation ../vocabulary-32/.runtime/demo-live/val.json \
  --out .runtime/we-audit
```
