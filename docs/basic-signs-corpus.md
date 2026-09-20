# Small temporal coordinates → sign corpus

The separate [32-word presentation subset](demo32-and-spelling.md) reuses these
coordinates without modifying this frozen 16-word corpus.

This is the small-data alternative to downloading the full 46 GB ASL Citizen
video archive. **No full archive is downloaded.** The script only makes bounded
HTTP range requests for the ZIP index/metadata and selected videos.

## Vocabulary and size limits

16 starter labels, chosen before tracking:

HELLO, YES, NO, PLEASE, THANKYOU, HELP, WATER, MORE, FINISH, GOOD, BAD, NAME,
MY, SORRY, STOP, YOU.

These are dataset glosses, not an assertion that every signer uses the same
variant or that these cover “all basic ASL”. There is no fingerspelling or
continuous-sentence annotation in this subset.

For each label:

- Six training/reference clips from six different signers.
- Two official validation clips, for future rejection/threshold selection.
- Three official test clips, not training examples.
- Ten additional unsupported-sign challenge clips in each of validation/test.

Total: **196 clips** = 96 train + 42 validation + 58 test.
The original official signer split is preserved and checked disjoint. Selection
is deterministic and independent of tracking or classification output. Some
source clips were used in earlier project experiments: this is not a fresh live
holdout. Unsupported signs are **not** a substitute for natural nonsigning data.

The frozen selected videos total **102.45 MB compressed**. Existing caches cover
75 clips, leaving **121 new clips / 62.94 MB compressed**. ZIP metadata/index is
about 12.34 MB per invocation. The CLI refuses a plan above 110 MB of selected
video payload or more than 150 MB of actual range data in one run.

Each newly downloaded clip exists only in an owned temporary directory while
being processed. It is removed afterward. Existing research video caches are
read-only and never deleted by this tool. Only coordinates and manifests are
retained in the new corpus.

## Completed local dataset

September 19, 2026:

- **196 coordinate sequences / 8,067 sampled frames**, all planned clips retained.
- **8,561,823 bytes (8.56 MB)** of compressed coordinates; about **8.71 MB**
  including the private manifest, reports and license.
- 22 training, four validation and 11 test signers; no split overlap.
- No newly retained `.mp4` files or temporary input directories.
- All arrays passed shape, timestamp, mask, finite-value, expression-range,
  hand-association and frozen-plan checks. The 89-test Python suite passed.
- Manifest SHA-256:
  `0f69613b93165d4c38b0efea82b687b658f1dc4035ff07a66a35d8f701a8ef2f`.

Five clips have fewer than six frames with hand observations: one training NO,
two training BAD, one test BAD and one test FINISH. They remain explicitly
represented; a future matcher should reject unusable training references and
count held-out failures rather than silently drop them.

Hands occur in 3,306/8,067 sampled frames, usable shoulders in 8,066 and a face
in 8,058. These sequences include idle portions. Those are **observation
availability counts, not tracking accuracy or sign-recognition accuracy**.

Transient connection/DNS failures interrupted extraction twice. Resume reused
completed coordinates without recomputing them. Bounded range retries now back
off, charge attempted bytes against the per-run budget, and never fall back to
downloading the full archive.

## Temporal extraction

The same model versions/hashes and detector options as build 11:
MediaPipe Tasks 0.10.21 Hand Landmarker, Pose Landmarker Lite, Face Landmarker.
The Python and iOS adapters have matching configurations; bit-exact cross-platform
inference parity has **not** been established.

Process the **entire isolated clip at a 15 Hz target cadence**, without mirrored
inputs, gesture trimming or selecting only “good” frames. All three detectors see
the same selected source image/timestamp. Each clip gets fresh tracker state.
Read/decode/model failures stop the run instead of silently removing samples.

Store compact compressed NumPy arrays, not video or verbose per-frame JSON:

| Array | Shape / meaning |
| --- | --- |
| `timestamp_ms` | T capture-relative timestamps, starting at zero |
| `hands` | T × 2 × 21 × 3, raw detector slots |
| `hand_valid` | T × 2 explicit observation masks |
| `hand_sides` | T × 2: -1 unassigned, 0 pose-left, 1 pose-right |
| `pose` | T × 25 × 3, original MediaPipe IDs 0–24 |
| `pose_valid` | T × 25 visibility/presence gates |
| `pose_confidence` | T × 25 × 2, visibility and presence |
| `face_anchors` | T × 18 × 3; nose, forehead, chin, eye/brow/lip anchors |
| `face_ids` | Original mesh IDs corresponding to those 18 anchors |
| `face_valid` | T explicit face-observation mask |
| `blendshapes` | T × 52, named facial movement coefficients |
| `blendshape_names` | Exact channel names; empty only if no face in the whole clip |
| `width`, `height`, `source_fps` | Source geometry/cadence |
| `plan_sha256`, `source_sha256`, `stats` | Provenance and tracking diagnostics |

All coordinate/score matrices are float32; masks and assignments use compact
boolean/integer types. Missing geometry is stored as zero **with its mask false**,
not as an observed zero pose. Hand slots can reorder, so matching must use the
current wrist association and handle ambiguous/unmatched frames.

We deliberately do **not** save all 478 face points per frame. The 18 anchors
plus expression coefficients retain a useful small starting representation;
they do not capture every ASL nonmanual feature. The app still exposes its full
face mesh for probing. Facial coefficients are not emotion/sentiment labels.

Coordinates remain normalized to the source image. z belongs to each detector's
own depth convention, not a shared metric skeleton. A future matcher must handle
aspect ratio, body/palm scale, handedness, missing data and signing speed rather
than compare raw coordinates blindly.

## Local usage

Canonical private output: `<checkout>/.runtime/basic-signs-v1/`.
No research data or derived reference coordinates belong in Git or the app.

```sh
# Use an optional research venv with MediaPipe 0.10.21, NumPy, OpenCV.
python -m backend.basic_signs plan \
  --out .runtime/basic-signs-v1 --accept-research-license
python -m backend.basic_signs extract \
  --out .runtime/basic-signs-v1 --models ios/Signloop/Resources \
  --cache path/to/existing/clips path/to/other/existing/clips \
  --accept-research-license
python -m backend.basic_corpus .runtime/basic-signs-v1 \
  --out .runtime/basic-signs-v1/validation.json
```

Existing complete coordinate files resume only under the same frozen plan hash.
Interrupted partial reports say `complete: false`; the corpus reader refuses
them. Do not run two extractors against the same output directory.

```python
from backend.basic_corpus import samples

for metadata, arrays in samples(".runtime/basic-signs-v1", split="train"):
    label = metadata["label"]
    timestamps = arrays["timestamp_ms"]
    hand_sequence = arrays["hands"]
    # Label applies to this complete isolated sequence, not every frame.
```

## What this does—and does not—deliver

This provides labeled **motion sequences**, not a classifier already proven to
recognize live signing. Next: normalize comparable features, evaluate temporal
similarity/DTW against training references, set rejection using validation only,
then test on reserved clips and fresh phone signers. Do not force a nearest word
when the input is unsupported, idle or uncertain. Continuous sign segmentation
and transitions need their own evidence.

The dataset preparation task did not change build 11. The subsequent
[build 12 matching experiment](basic-live-matching.md) consumes private training
features on-device, without a backend or transcription. Its weak initial replay
results do not establish reliable recognition of these 16 labels.

## Research restrictions

Source: [ASL Citizen](https://www.microsoft.com/en-us/research/project/asl-citizen/).
The [research license](https://www.microsoft.com/en-us/research/project/asl-citizen/dataset-license/)
restricts use to noncommercial, non-revenue-generating research and prohibits
redistributing data or its modifications. No upload to Jev/other providers,
GitHub, teammates, or a distributed app. Destroy personal data and its copies
when the research ends. Commercial/distributable reference data needs separate
permission or appropriately consented/licensed recordings.
