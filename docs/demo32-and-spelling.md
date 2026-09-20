# 32-word research vocabulary and separate spelling

Build 15 extends the standalone native scanner, not the separate Expo app.
It remains entirely offline. Word reference data are private and provisioned
separately; the MIT-derived static-letter model is bundled with attribution.
This is not general ASL translation, sentence understanding or a validated
accessibility-critical communication aid.

## Vocabulary

Original 16: HELLO, YES, NO, PLEASE, THANKYOU, HELP, WATER, MORE, FINISH, GOOD,
BAD, NAME, MY, SORRY, STOP, YOU.

New 16: ILOVEYOU, WE, OUR, NICE, MEET, TODAY, PROJECT, TECHNOLOGY, COMPUTER,
PHONE, SIGNLANGUAGE, UNDERSTAND, LEARN, SHOW, MAKE, CAMERA.

These are dataset glosses, not promises of identical regional variants.
`ILOVEYOU` means the conventional thumb/index/pinky handshape, not an English
sentence synthesized from unrelated observations. We do not relabel PROJECT,
PHONE or COMPUTER as “app”: APP and Signloop can be fingerspelled.

The camera still displays the **best current guess**, not a confirmed sign.
Adding competing classes can reduce the accuracy of existing ones. Unsupported
movements can receive a supported label; scores are not calibrated probabilities.
The 32-word bank uses the same hand-local geometry, shoulder/chest location and
causal temporal pipeline as build 14. Face inference remains off by default.

## Presenting yourself

1. Use **Signs** for HELLO, MY, NAME.
2. Switch to **Spell name** for A–U–R–E–L–I–O.
3. Show exactly one hand, hold each letter briefly, verify the guess and tap
   **Add**. Repeated letters need separate taps; nothing is written automatically.
4. Use delete to correct the draft. **Manual** contains J, Z, space and clear.
5. Switch back to **Signs** for the word demonstration.

Useful presentation concepts: TODAY, WE, SHOW, OUR, PROJECT, PHONE, CAMERA,
SIGNLANGUAGE, HELP, UNDERSTAND, LEARN, THANKYOU. This list is **not an ASL grammar
lesson or a generated sentence**; have an ASL-fluent person help arrange a
natural presentation. English filler words such as “is” need not have individual
signs in an ASL introduction.

The spelling draft is local RAM only and disappears on a fresh app launch.
Letters and word signs never compete in the same classifier. Only the selected
mode runs inference. Camera pause/switch/staleness and mode changes invalidate
in-flight estimates. Letter recognition does not require a detected shoulder.

### Alphabet scope

**24 static letters are modeled. J and Z are manual, not detected.** They require
motion evidence that this source dataset does not supply. All seven letters in
AURELIO and all letters in SIGNLOOP are in the modeled subset. The entire alphabet
is available for composition only with that explicit manual exception.

The source collection scripts saved unmirrored webcam coordinates (unlike their
separate mirrored preview script). **Mirror letter input** in Settings is off
by default and can be switched if signing-hand orientation differs.
The model uses absolute image coordinates and engineered hand distances;
it is not proven invariant to camera framing, signing hand or a new signer.

## Alphabet provenance, training and verification

Source: [Siruyy/realtime-asl-recognizer](https://github.com/Siruyy/realtime-asl-recognizer),
MIT, © 2026 Neria, revision `74b976b536ab8318dab756a3071a681d5c75bcb0`.
See the complete notice in `ios/Signloop/Resources/alphabet-license.txt`.
The source includes labeled MediaPipe coordinates, engineered feature matrices
and an MLP. No upstream Python or pickle was executed. Label order was checked
from pickle bytecode literals; matrices were loaded with `allow_pickle=False`.

The published static model produced only **465/936** correct on the checked
source sample set with its supplied normalization. Therefore it is **not bundled**.
Signloop trains its own small MLP on the labeled coordinate matrix:

- 3,744 source training samples, excluding J/Z.
- 2,997 fitting samples and 747 internal validation samples; deterministic
  class-balanced split within source train only.
- Normalization fitted only on those 2,997 fitting samples.
- Early stopping on internal validation selected epoch 76; 731/747 correct.
- Frozen model evaluated on 936 source test samples: **913/936 (97.5%)**.
- Native Swift/Accelerate matches the exported NumPy network's top label on
  all 936 samples; maximum score difference below `1e-6`.

**These are sample splits with no signer/session IDs.** The source test was
already inspected for the published-model comparison; this is not a fresh blind
test. Adjacent observations may be highly correlated. Neither 97.5% nor the
upstream author's claim establishes live iPhone or held-out-signer accuracy.
The UI consequently asks for explicit confirmation rather than automatic text.

The 86-feature extractor is ported with parity checks, not approximated using
the word matcher's different normalization. Native inference uses a small dense
network, not a backend, TensorFlow runtime or image upload. Reproduction:

```sh
# Clone the pinned source into ignored .runtime/alphabet-upstream.
# In a research venv with numpy and torch:
python -m backend.alphabet_train \
  --upstream .runtime/alphabet-upstream \
  --out ios/Signloop/Resources/alphabet-static.json \
  --fixture .runtime/alphabet-trained-fixture.json
```

`backend.alphabet_export` preserves the unsuccessful published-model replication
path (requires h5py) for auditing; do not overwrite the shipping trained model
with it inadvertently.

## Word data expansion

`backend.basic_signs --vocabulary demo32` freezes 372 selected clips:
192 train, 74 validation and 106 test. Six/two/three distinct official signers
per label respectively; ten unsupported challenges in each evaluation split.
Official signer splits remain disjoint. Existing 16-label coordinates are
reused only after exact sample, archive, model, sampling and manifest checks.
No invented reference coordinates or relabeling of old test data.

The selected video payload totals about 204 MB, **not the 46 GB archive**.
Reused coordinates avoid repeating the original processing/downloads. Actual
network reads are bounded at 150 MB per extraction invocation, including retries.
New clips live only in owned temporary directories and are deleted after
coordinate extraction. Existing caches are read-only.

ASL Citizen derivatives remain private noncommercial research material, not
bundled, uploaded, committed or redistributed. Expanding the vocabulary does not
change that license boundary.

### Completed expansion and word evaluation

- All **372 clips** processed, **16.88 MB** compressed coordinates.
- All 196 original sequences were reused exactly (only their manifest binding
  changed). No new `.mp4` files or temporary inputs remain.
- Actual range bytes this extraction: **107.57 MB**, including ZIP metadata.
- **165 usable training references**, covering every one of the 32 labels;
  packed private phone bank **4.59 MB**. No evaluation examples in that bank.
- Frozen corpus manifest SHA-256:
  `dd98057cf8cccaea8dd59a7e09341d515b7853c5c3edd1cbb3fcc369cbdaaabf`.

Nine configurations were compared on validation only: 1200/1800/2400 ms windows
and 0/0.1/0.2 anatomical-rule weights. The 32-word set selected **1200 ms,
weight 0**, four observations spanning at least 180 ms. Thus the 32-word bank
uses the trajectory/3D geometry, but **does not apply the optional anatomical
penalty**; the larger candidate set did better without it on validation.
The untouched 16-word bank still supports its build-14 parameters.

| Most frequent raw guess per supported clip | Correct | Any usable guess |
| --- | ---: | ---: |
| Expanded validation | 35 / 64 | 57 / 64 |
| Expanded existing official test | 53 / 96 | 83 / 96 |
| Original 16 within that test | 25 / 48 | 37 / 48 |
| Additional 16 within that test | 28 / 48 | 46 / 48 |

The original 16 previously scored 26/48 with their smaller candidate set.
The new test samples were evaluated only after this selection, but the original
cohorts have already been inspected, so the combined result is not a fresh blind
test. Ties use the first encountered most-frequent candidate; no-evidence clips
remain in the denominator.

ILOVEYOU, OUR, TODAY, PHONE and CAMERA each scored 3/3 most-frequent guesses;
NICE and SIGNLANGUAGE scored 0/3. YOU regressed from 1/3 to 0/3; PLEASE and MY
remained 2/3. **All 10 unsupported clips received a guess.** These very small
per-label cohorts are not enough to promise live accuracy. No post-test tuning
was performed. The disabled strict acceptance gate keeps guesses marked
uncertain, rather than suggesting the scores are calibrated probabilities.

The optimized Mac replay took 15.24 seconds total for 106 clips / 3,418 scheduled
events, including missing-input events. This is not an iPhone latency measurement.
The alphabet's 97.5% source-sample result is a different task/dataset and must not
be substituted for the 32-word recognition result.

### Verification and deployment

46 word-matcher invariants, 161 legacy core checks, 106 Python tests and 1,891
alphabet feature/inference/async-adapter checks passed. Thirteen optimized Debug
simulator UI tests passed, including manual J/Z, explicit Add, mode changes,
ephemeral drafts and large text. A large-text layout issue found during testing
was fixed before the final pass. Signed Release build 15 passed signing checks;
the app bundles the 1.38 MB MIT-derived alphabet model and attribution, but no
private word bank, source sample matrices or provider keys.

Private reproduction/provisioning (inside the retained `vocabulary-32` worktree):

```sh
python -m backend.basic_live provision \
  --out .runtime/demo-live \
  --corpus ../../.runtime/demo-signs-v1 \
  --device YOUR_DEVICE_ID --accept-research-license
```

Use the **packed** schema-2 bank; do not provision the larger raw training JSON.
Word/letter guesses require a real phone check after installation. Build/install
and replay evidence alone do not validate live camera recognition.

September 19, 2026, 20:08: **build 15 installed on Yeyito**, and all 165 private
training references were copied successfully. Launch was denied because the
phone was locked; unlock and open Signloop. The simulator separately loaded the
real packed bank and displayed “32-sign research preview” / “Watching…” without
inventing a sign when camera evidence was absent.
