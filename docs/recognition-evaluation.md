# Local reference recognition, not zero-shot number guessing

**[First real-recording results](recognition-baseline-results.md):** 9/30 supported
clips recognized; 15/15 unsupported clips rejected, but 20/45 test clips failed
observation-quality gates. This is not ready for deployment.

**[Hand-association follow-up](recognition-tracking-results.md):** V2 recovered
most unusable calibration sequences; a fresh signer-disjoint test recognized
7/14 supported clips and falsely accepted 1/15 unsupported clips. Still not ready.

## What changed

The existing Jev adapter sends six subsampled frames plus written descriptions,
not labeled examples. Its acceptance threshold and the app's two-result filter
can suppress weak results; lowering those gates does not establish accuracy.

`backend.matcher` is an independent, dependency-free baseline:

1. Load explicitly labeled **developer** recordings, never save live requests.
2. Correct image aspect ratio and mirroring; wrist-anchor and palm-normalize
   handshape, preserve orientation, wrist movement, and two-hand relative position.
3. Time-sample to at most 24 observations. Compare to each training reference
   using banded dynamic time warping (DTW).
4. Rank the nearest reference per label. Reject distant or ambiguous matches.
5. Return the same app-facing candidates/unknown contract. A similarity
   `exp(-distance)` is **not a probability**. The backend, not a second hardcoded
   iPhone score threshold, owns model-specific acceptance.

The iPhone now includes `imageAspectRatio` and `mirrored` frame metadata. The
old payload lacked these, making portrait-phone versus landscape-video numeric
comparisons geometrically inconsistent. Old recordings without metadata assume
square, mirrored coordinates; do not mix these with new recordings unknowingly.
The camera screen and two-consecutive-result stabilization are unchanged.

## Offline unit and integration tests

```sh
scripts/dev/signlooptest . backend
python3 -m backend.test_native
bash ios/scripts/test-core.sh
```

Synthetic fixtures test invariance, motion order, orientation, two-hand
visibility, unknown rejection, malformed input, calibration/test isolation,
duplicate recordings, signer leakage, report binding and the HTTP contract.
They are explicitly **not ASL recordings or accuracy evidence**.

The default remains `reference-dtw-v1` for reproducibility. Opt into geometric
hand association with `backend.research_data --matcher reference-dtw-v2` and
`backend.replay --model reference-dtw-v2`. Keep versioned corpus/report filenames.
Their reference corpora remain local research assets, not bundled iPhone data.

The [native Swift V2 engine](native-temporal-matcher.md) is now parity-tested,
but has no bundled references and is not enabled in the camera UI.
[Rolling calibration and mirror augmentation](recognition-stream-calibration.md)
are separate research experiments; their results do not establish demo-ready
multi-sign accuracy.

## Bring a real corpus

JSON format:

```json
{
  "version": 1,
  "dataset": "Consented developer recordings",
  "samples": [{
    "id": "unique-recording-id",
    "label": "YES",
    "signer": "anonymous-signer-a",
    "source": "documented source/consent",
    "split": "train",
    "frames": [{
      "timestampMS": 0,
      "imageAspectRatio": 0.5625,
      "mirrored": true,
      "hands": []
    }]
  }]
}
```

The abbreviated frame above is schema illustration, **not a usable reference**.
Use at least six tracked frames, <=90 frames and <=3 seconds per recording,
with each hand's handedness and 21 finite xyz joints (same as camera export).
Split by **signer**, not frames or windows: `train`, `calibration`, `test`.
Require at least two known labels and include every known label plus `UNKNOWN`
in calibration/test. Use unsupported signs, nonsigning movement, transitions,
and confusing handshapes as negatives. Never make shifted copies of a training
clip the test set. The loader refuses cross-split signers and duplicate geometry.

```sh
python3 -m backend.replay .runtime/corpus.json --out .runtime/report.json
```

Only training examples become references. A fixed threshold/margin grid is
selected on calibration examples, maximizing recognized known signs subject to
zero false accepts on the calibration negatives. Then parameters are frozen and
the held-out test set is evaluated once. Zero calibration errors is **not** a
guarantee, especially with few negatives. Do not tune features against the test
results; further iterations need fresh held-out data.

The report gives a confusion matrix, known accuracy after rejection, nearest
label accuracy before rejection, unknown false-accept rate, accepted precision,
coverage, unusable observations, latency and per-recording rejection diagnostics.

To exercise the real local HTTP endpoint without Jev or Cerebras:

```sh
# Set SIGNLOOP_BACKEND_TOKEN (>=24 characters) in an ignored environment file.
python3 -m backend.server --env-file ../../.env --host 127.0.0.1 --port 8788 \
  --reference-corpus .runtime/corpus.json --calibration-report .runtime/report.json
```

Use the correct environment-file path for your checkout. No provider key is
needed in reference mode; captions are disabled. Corpus SHA-256 and model version
must match the calibration report. No raw request logging or saving is added.

## ASL Citizen: local noncommercial research only

Source: [Microsoft ASL Citizen](https://www.microsoft.com/en-us/research/project/asl-citizen/),
[paper](https://arxiv.org/abs/2304.05934).
Read the [dataset license](https://www.microsoft.com/en-us/research/project/asl-citizen/dataset-license/).
This is **not** an unrestricted dataset: do not redistribute videos, annotations,
or derived landmarks, upload them to Jev, or bundle these references in an app.
Keep notices; delete local copies when the research ends. Contact the dataset
owner for uses outside the license. Only aggregate research results are committed.

The optional importer reads byte ranges for selected clips from the official ZIP,
not the entire 46 GB archive. It keeps official signer-disjoint splits and picks
recordings deterministically, without looking at predictions.

```sh
python3.12 -m venv .runtime/research-venv
.runtime/research-venv/bin/pip install \
  mediapipe==0.10.21 opencv-python-headless==4.11.0.86
.runtime/research-venv/bin/python -m backend.research_data \
  --accept-research-license
python3 -m backend.replay .runtime/asl-citizen/corpus.json \
  --out .runtime/asl-citizen/report.json
```

The importer uses the same MediaPipe version/model/confidence thresholds as the
phone, but desktop video decoding/inference is not identical to the iPhone.
Its fixed center <=3-second crop and no-hand edge trim are **isolated-clip
preprocessing, not live segmentation**. Unusable training clips are enumerated;
unusable calibration/test clips stay in their denominators. Unknown examples here
are other ASL signs, **not** a representative sample of everyday nonsigning.

The server refuses to expose a `redistribution: PROHIBITED` corpus on non-loopback
interfaces. Do not serve this research corpus to the phone or a hosted endpoint.
Keep all local research files under ignored `.runtime/`.

## Before replacing the phone classifier

- Obtain distributable/consented references for the actual supported vocabulary.
- Confirm signs/labels with an ASL signer, including variants.
- Test real iPhone 1.2-second rolling windows, no-sign inputs and transitions, not
  just isolated clips with trimmed edges; add segmentation or adjust windows.
- Measure on a held-out signer, lighting, camera distance, orientation and speed.
- Hands alone lack face/chest context for PLEASE/THANK_YOU and many other signs.
- Jev reranking is optional and untested. Only send appropriately licensed,
  consented examples; compare it against the numeric baseline on fresh test data.

This work adds an evaluation path, not proof of usable ASL translation. It neither
embeds API keys, removes the Mac dependency, nor enables transcription.
