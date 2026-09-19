# Temporal hand-association experiment — 2026-09-19

**Still experimental, not ready for deployment.** This follow-up changes hand
association, not sign descriptions, and makes no Jev/Cerebras calls.

## Change

`reference-dtw-v2` uses observed wrist proximity, normalized handshape and a weak
handedness cue to associate up to two detections across frames. It removes
near-identical duplicate detections, tolerates transient handedness errors,
expires stale associations after 300 ms, and abstains on assignment ties.
It never invents hands or fills occlusion gaps with synthetic landmarks.

The feature/distance calculation and calibration grid are otherwise unchanged.
V1 remains available for reproducibility. Corpus-bound reports specify the matcher
version; the server will not silently apply a V1 operating point to V2.

This is a geometric heuristic, not a validated hand-ID tracker. Crossings,
occlusions and initially incorrect handedness can still cause errors.

## Protocol

- Same original training/calibration clip selection and frozen MediaPipe outputs.
- V2 recovered 8 previously unusable training clips: **27 references**, 15 signers.
- Calibration remains **32 clips from 4 signers**. Unusable observations fell
  from **11 to 1** on this same set, but correctly recognized supported clips
  remained 9/17. Better tracking alone does not solve recognition.
- Calibration operating point: maximum distance **0.55**, relative margin **0.1**.
- Fresh holdout: **29 clips from 9 previously unused signers**, none present in
  any of the original 107 selected clips, including rejected training clips.
  These are unused official-train participants reserved for a new local test;
  they are never used for training or calibration.
- Fresh selection used metadata only, before any predictions. Some labels have
  fewer available new signers than the requested cap of six.
- Corpus SHA-256:
  `fc86b68b116b31d593af34b2c5b436b8a190f42d4c9c56c0a6d0e4865cec794b`.

## Fresh held-out results

| Ground truth | Correct | Unknown | Wrong label |
| --- | ---: | ---: | ---: |
| HELLO | 1/3 | 2 | 0 |
| YES | 1/2 | 1 | 0 |
| NO | 0/3 | 3 | 0 |
| PLEASE | 2/2 | 0 | 0 |
| THANK_YOU | 3/4 | 1 | 0 |
| Unsupported signs | 14/15 rejected | 14 | 1 (YES) |

- Known accuracy after rejection: **7/14 = 50%**.
- Nearest-label accuracy before rejection: **10/14 = 71.4%**.
- Accepted precision: **7/8 = 87.5%**; total coverage **8/29**.
- Unsupported false-accept rate: **1/15 = 6.7%**.
- One unusable test observation.
- Mean local classification time: **66.0 ms**, including association, feature
  extraction, matching and fast quality rejection. Not measured on an iPhone,
  and not camera-to-display latency.

The V1 and V2 held-out cohorts are different, so 30% versus 50% is **not a
controlled accuracy improvement measurement**. The same-calibration quality
recovery is direct evidence of a narrower improvement. Also, V2 calibration
accepted three wrong known labels: accepted precision was only 75% despite zero
unsupported-sign false accepts. Threshold policy must consider both error types.

## Reproduce locally

Read the research-only dataset restrictions in
[recognition-evaluation.md](recognition-evaluation.md). Do not publish the corpus,
ship it to the phone, or upload it to a provider.

```sh
.runtime/research-venv/bin/python -m backend.research_data \
  --accept-research-license --matcher reference-dtw-v2 \
  --fresh-signers --corpus-name corpus-v2.json
python3 -m backend.replay .runtime/asl-citizen/corpus-v2.json \
  --model reference-dtw-v2 --out .runtime/asl-citizen/report-v2.json
python3 -m unittest backend.test_service backend.test_matcher backend.test_hand_tracking -v
```

Synthetic tests cover brief label flips, detection-order changes, duplicate
detections, no fabricated hands, assignment ambiguity, expiry and fresh-signer
selection. Those tests are not sign-recognition accuracy evidence.

## Remaining work

- Improve recognition and confidence selection using training/calibration only.
- Test extra hand/body context and motion descriptors, especially fist nods,
  finger closing and body-relative THANK_YOU/PLEASE gestures.
- Obtain distributable/consented phone recordings and fresh independent tests.
- Evaluate rolling windows, segmentation and actual phone latency/UX.

No phone deployment, cloud service, or transcription was enabled.
