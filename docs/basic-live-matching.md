# Private offline 16-label matching experiment

For the subsequent 32-word expansion and static-letter mode, see
[build 15](demo32-and-spelling.md). The results below describe the 16-label bank.

## Build 14: best guesses, geometric rules and shared temporal evidence

The standalone scanner now shows **Best guess** whenever usable temporal evidence
exists, even when the rejection policy would reject it. **Watching…** means no
usable candidate yet, not a forced label. Guesses are explicitly uncertain:
unsupported movements also get a closest supported label. Similarity bars remain
independent scores, **not probabilities**. This changes the display policy, not
the certainty of the model.

The previous matcher already used temporal DTW, but let each class select its own
best window. The new matcher compares every class on the same causal 1.2-second
window, adds wrist direction/path and palm-rotation features, and resets the
episode after a 300 ms hand/body evidence gap. Four usable observations spanning
180 ms allow an earlier first guess; that is a minimum evidence span, **not a
measured phone latency**. Training references still require six observations.

Hand shape now uses palm-normalized **hand-local XYZ**, plus rotation-invariant
pairwise joint distances. This avoids the old XY palm-scale collapse for
camera-facing pointing. Depth is never compared between separate pose/hand
models. Soft anatomical hints distinguish pointing, open hands, fists, selected
finger extensions and clustered fingertips. These are incomplete per-sign
heuristics, not hand-invented labeled examples or complete ASL definitions.
MY/PLEASE also benefit from trajectory information rather than hand shape alone.

**Track face (slower)** is off by default. Face inference and its initialization
are skipped entirely; hand and Pose Lite tracking remain for shoulders/chest,
elbows and wrists. Face overlays can be re-enabled for inspection, but facial
features do not affect this matcher. Reference trajectories and intrinsic hand
features are cached; preview never waits for the serial matching worker.

### Development evidence and limitations

Nine window/rule-weight configurations were compared on the existing validation
split (selected 1200 ms / 0.1 rule weight). These cohorts have been inspected
before: they are **not a fresh blind test**, even though their signers are
disjoint from the training references.

| Most frequent raw guess per supported clip | Build 12/13 matcher | Build 14 |
| --- | ---: | ---: |
| Validation | 21 / 32 | 22 / 32 |
| Existing official test | 21 / 48 | 26 / 48 |
| Test clips with any usable guess | 34 / 48 | 37 / 48 |

This is a plurality-of-guesses metric, not frame accuracy or the old
“correct confirmed caption at least once” metric below. No-evidence clips stay
in the denominator. YOU improved from 0/3 to 1/3, MY from 1/3 to 2/3,
PLEASE stayed 2/3, YES improved 2/3 to 3/3, and SORRY regressed 3/3 to 2/3.
**All 10 unsupported test clips received some guess.** The old constrained
acceptance calibration found no useful policy for the new distances; its
maxDistance=0/minMargin=1 keeps all guesses marked uncertain. This is not solved
recognition or reliable continuous ASL translation.

On three public static fixtures, native simulator detection took about
26–42 ms median with face off, versus 32–48 ms with it on (roughly 6 ms saved).
Both modes cleared stale detections on a blank image. This does **not** establish
live iPhone FPS, camera-to-caption delay, or signing accuracy.

Three alternating optimized Mac replays of the same 42 validation clips took
2.33 seconds total for the old matcher and 2.59 seconds for the new matcher
(median run totals). The more detailed matcher is **not faster in that test**;
face skipping and earlier evidence eligibility are the latency improvements,
not a claimed across-the-board inference speedup.

Verification: 44 matcher/async-adapter invariants plus the legacy 161-check
core suite passed; 103 Python tests passed. Ten optimized Debug simulator UI
tests passed. Caching preserved all candidate labels, distances and margins
exactly across 3,284 scheduled events in 100 validation/test clips. The final
signed Release build 14 passed signing and secret/bundle checks. Yeyito was
unavailable at the final check, so build 14 is **ready, not installed**.

Build 14 requires the separately provisioned **schema-2** packed research bank.
Old packed schema-1 banks are rejected rather than silently interpreted as XYZ.
No references, footage or provider secrets are bundled. Raw schema-1 training
frames can be re-exported through the new matcher; old packed features cannot.
Private evaluation/reproducibility files remain in the task's ignored
`.runtime/final/`. Install the app, provision that directory's new bank with
`backend.basic_live provision`, then launch. Public redistribution of these
research data remains prohibited by the source terms.

## Historical build 12/13 behavior and evaluation

The skeleton camera now feeds an on-device temporal reference matcher. The screen
shows **Possible sign** / **Unknown**. No backend, keys, transcription, recordings,
or camera uploads. This is a research baseline, **not reliable 16-sign recognition**.

## Build 13: optional live score panel

Settings → **Show all sign scores** enables a camera overlay with all 16 labels,
stable vocabulary order, percentage bars and a highlighted nearest label.
Scroll if needed; accessibility text sizes use one column. The setting is off
by default, persists across launches, and the panel's close button turns it off.

These are **independent similarity scores, not calibrated probabilities**:
`similarity = 100 × exp(-DTW_distance / 0.08)`. This fixed display transform
preserves the distance ranking; it is not fitted to probabilities and the scores
do not sum to 100%. Zero distance displays 100%; distance 0.08 is about 37%.
No evidence or missing usable references displays **—**, not a made-up zero or
uniform probability distribution.

Every label's distance comes from the same reference/window search that already
drives recognition; the panel adds no model calls or reference examples. Scores
remain visible when distance/margin rejection keeps the caption Unknown.
They clear on pause, camera change, stale/delayed results, hand/pose loss and
insufficient temporal evidence. A high score does not override rejection.
The original classifier and rejection thresholds are unchanged; this is a
debugging/visibility improvement, not an accuracy claim.

Build 13 verification: 36 matcher/async-adapter checks and the rest of the Swift
core suite passed; all candidate events across the 42 validation clips matched
build 12 exactly. Ten Release simulator UI tests passed, including toggle
persistence/hiding, missing-score placeholders, list access and large-text
camera controls. The panel respects header/controls safe areas and has separate
accessible rows. The signed Release iPhone build passed signing verification.
Yeyito was unavailable at the final device check, so this update still needs
installation after reconnection; build 12 remains the last installed version.

## Pipeline

Same-frame MediaPipe hands + shoulders/elbows/wrists + facial movement coefficients
→ aspect-corrected, shoulder-relative locations and palm-normalized hand shape
→ 0.7 / 1.4 / 2.4-second causal windows → dynamic time warping against training
references → distance and competing-label rejection → two consecutive matches.

Hands use physical pose association where available, otherwise the nearest
unambiguous visible pose wrist. Left/right mirrored matching accommodates
dominance, but may erase meaningful asymmetries; this remains experimental.
Image XY is used, **not mixed cross-model depth**. Facial blendshapes have low
weight and are not emotion or ASL grammar labels. The full face mesh remains
visible/probeable but is not all used in this classifier.

Six usable hand/body observations spanning at least 300 ms are required.
Sequences are trimmed to first/last usable hands, resampled to 16 temporal steps,
and compared with banded DTW. Missing observations inside a sequence remain masked.
These windows are not a continuous sentence segmenter. Static poses and natural
nonsigning need further testing; unknown rejection is not a guarantee.

Matching runs on a separate serial worker, at most one job in flight and at most
one request per 100 ms. Capture/preview never wait for a matcher. Camera pause,
switch, interruption, stale frames and hand loss invalidate older results.
There are no calibrated confidence percentages. The displayed word is tentative.

## Frozen development evaluation — September 19, 2026

Source: [the 196-clip compact corpus](basic-signs-corpus.md).
Only its 96 official training clips are considered references; 75 pass the
hand/body temporal quality gate. All 16 labels remain represented, with two to
six usable references per label. Evaluation retains missing/poor-tracking clips
in its denominators. Training, validation and test signers are disjoint.

Validation selected max DTW distance **0.08**, minimum relative competing-label
margin **0.15**. The initial 200 ms request interval displayed 10/32 correct;
100 ms displayed 11/32. A four-observation/180 ms variant failed the validation
error constraint and was rejected; the six-observation policy was retained.
No policy tuning was performed on the test results.

| Streaming replay | Validation | Reserved official test |
| --- | ---: | ---: |
| Supported clips | 32 | 48 |
| Correct label displayed at least once | 11 (34%) | 11 (23%) |
| Wrong supported label displayed at least once | 1 | 5 |
| Unsupported clips with any display | 0 / 10 | 0 / 10 |

Correct/wrong counts can overlap within a clip; they are not classifier accuracy
percentages over frames. HELLO displayed correctly in 3/3 test clips; PLEASE in
2/3. That is a useful starting point for phone testing, not a claim of general
reliability. Several labels never displayed correctly in this tiny test.
Some source videos appeared in earlier experiments, so these results are not a
fresh project-wide blind evaluation.

Replay uses the actual Swift feature, DTW and rejection code, causally, with
no future frames and no full-clip oracle at inference. Packing/unpacking private
training features reproduces the raw-bank validation candidate events exactly.
The final replay explicitly clears confirmation on every hand/pose-loss frame,
including frames between requests, matching the live adapter. Correcting this
replay detail left validation thresholds/correct displays unchanged and removed
one spurious test wrong-display count (six → five); it was not a model change.
Wall-clock worker/camera contention and live iPhone acquisition are not simulated.
Unsupported isolated signs are not representative natural nonsigning.

## Private provisioning, not redistribution

The app bundle and Git contain **no ASL Citizen reference data**. The development
tool produces a roughly 844 KiB private feature bank. It must only be copied to
the same user's research phone's Documents container, not teammates, providers,
a public demo download or a distributed app. On load it is excluded from device
cloud backups. Delete the file and other personal data when the research ends.
The [source license](https://www.microsoft.com/en-us/research/project/asl-citizen/dataset-license/)
requires separate permission/data for distributable or commercial use.

No private bank: the camera still tracks, with “Private references unavailable”.
The user does not enter a URL, key, or collect reference samples in the UI.
Provision before launch; quit/reopen if the bank was installed after launch.

From the task checkout (paths are examples; use the canonical existing corpus):

```sh
python -m backend.basic_live export --corpus ../../.runtime/basic-signs-v1 \
  --out .runtime/basic-live
swiftc -O -parse-as-library ios/Signloop/Skeleton.swift \
  ios/Signloop/BasicSignMatcher.swift ios/Tests/BasicSignReplay.swift \
  -o .runtime/basic-replay
.runtime/basic-replay .runtime/basic-live/basic-references.json \
  .runtime/basic-live/val.json .runtime/basic-live/val-raw.json
python -m backend.basic_live calibrate --out .runtime/basic-live \
  --raw .runtime/basic-live/val-raw.json
.runtime/basic-replay .runtime/basic-live/basic-references.json \
  --pack .runtime/basic-live/basic-references-packed.json
# Freeze the policy BEFORE this test; don't tune to its failures.
.runtime/basic-replay .runtime/basic-live/basic-references-packed.json \
  .runtime/basic-live/test.json .runtime/basic-live/test-raw.json
python -m backend.basic_live report --out .runtime/basic-live \
  --raw .runtime/basic-live/test-raw.json
# Install the signed app separately, then provision only training features:
python -m backend.basic_live provision --out .runtime/basic-live \
  --corpus ../../.runtime/basic-signs-v1 --device DEVICE_ID \
  --accept-research-license
```

Synthetic core tests cover identity distance, scale/aspect/translation invariance,
packing parity, insufficient/empty-input rejection, margins, stability resets and
held-out-reference refusal. These are software invariants, not human ASL tests.
Use a Release build on the phone for optimized DTW.

## Build verification

- 101 Python tests passed in the research environment.
- Swift core suite passed, including 21 new matcher/async-adapter checks and the
  existing 161 sign-engine checks. The optional Core ML model parity section
  was not configured and remains skipped.
- Eight Release simulator UI tests passed: missing-bank fallback, camera
  permission recovery/contrast, settings/three overlays, inspector, pause,
  privacy and large text. An old tracking-only assertion was updated for the
  new caption area; it still verifies that no sign is invented.
- A separately provisioned simulator loaded the compact bank, showed Unknown
  with no camera observations, and marked the private file excluded from backup.
- Signed Release iPhone build 12 passed code-sign verification. Source and app
  scans found no provider credentials; private reference data is not bundled.
- After reconnecting, build 12 was installed, its 75-reference private bank
  provisioned and the app launched successfully at 18:06 on September 19.
  The user subsequently reported it “kind of works” but is not great; that
  feedback is not a measured live accuracy result.

## Phone check

Stand alone with face, shoulders and hands visible. Begin with HELLO, then PLEASE.
Try one sign at a time and briefly relax between signs. Compare the tentative
label with what was actually signed. Also try natural nonsigning, no hands,
camera switch, pause/resume and poor lighting. Record aggregate observations
manually, not camera footage. New fluent-signer/live failures are needed before
claiming useful accuracy or expanding the vocabulary.
