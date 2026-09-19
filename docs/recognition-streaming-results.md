# Rolling-window diagnostic — 2026-09-19

**The whole-clip benchmark does not describe live UX.** This local experiment
exposes a timing mismatch without enabling a backend, changing the app's default
offline ILY preview, or changing any recognition thresholds.

## Protocol and boundaries

- Frozen `reference-dtw-v2`, distance 0.55 / margin 0.1.
- Same previously inspected V2 test clips: 14 supported, 15 unsupported.
  This is **development diagnosis, not a fresh held-out accuracy claim**.
- Corpus SHA-256:
  `fc86b68b116b31d593af34b2c5b436b8a190f42d4c9c56c0a6d0e4865cec794b`.
- Start with an empty buffer per clip, send only the preceding 1,200 ms, and
  require two consecutive accepted labels, like `RemoteRecognition`.
- Clear confirmation state on every no-hand frame, even between requests.
- Replay three fixed polling phases: zero, one-third and two-thirds of the
  interval. Polls snap forward to the next recorded frame; no future data is
  used, and no final pose is artificially held after the recording ends.
- Responses are immediate. **Network, inference and scheduling delay are not
  modeled**; this is not camera-to-display latency measurement.
- Uses the mathematical matcher, **not Jev**. It diagnoses that display policy
  with this matcher; it does not establish Jev's recognition accuracy.
- These are isolated clips, not continuous signing, transitions or ordinary
  non-signing activity. There are no annotated sign onsets.
- Three phases of each clip are correlated. There are 42 supported and 45
  unsupported clip/phase runs, **not 87 independent people/recordings**.

## Results

| Poll interval | Supported runs with any correct raw decision | Supported runs showing correct label | Unsupported runs showing a label |
| --- | ---: | ---: | ---: |
| 1,000 ms (current cloud cadence) | 20/42 | **1/42** | 0/45 |
| 500 ms (diagnostic only) | 26/42 | **10/42** | 3/45 |
| 250 ms (diagnostic only) | 30/42 | **24/42** | 8/45 |

No wrong supported-to-supported labels were displayed in these particular
replays. All displayed errors were unsupported signs accepted as supported.
NO was never correctly displayed at any cadence. No repeated same-label display
onsets occurred; this does not prove segmentation/deduplication for continuous
signing. Display onsets are not transcript emissions.

At 1 Hz, only 114 requests fit into 87 short clip/phase runs. The two-result
confirmation rule often cannot gather enough evidence before the clip ends.
Requiring two overlapping windows at 4 Hz is also **not two independent pieces
of evidence**: it increases both recall and false acceptance.

First correct display was a median 1,335 / 1,050 / 759 ms from **clip start**
respectively, among runs that displayed correctly. These values omit missed
signs and network/inference delay, and are **not sign-onset latency**.

## Verification

Seven synthetic scheduling/filter tests cover causal windows, short signs,
polling phase, no-hand resets between requests, unknown clearing, reappearance,
and wrong-known/unsupported accounting. Synthetic markers are not ASL.

Native Swift `LiveSignFilter` matched every Python replay decision:
177 + 268 + 452 = **897 events across 261 clip/phase runs**.
This verifies display-filter parity, not the entire asynchronous app scheduler.

## Reproduce locally

Keep research data and per-clip outputs local and ignored; the ASL Citizen
research restrictions still apply. Do not upload reports containing recording
identifiers or derived per-clip decisions to providers or Git.

```sh
python3 -m backend.stream_replay path/to/corpus-v2.json \
  path/to/report-v2.json --out .runtime/stream-1000.json
python3 -m backend.stream_replay path/to/corpus-v2.json \
  path/to/report-v2.json --interval-ms 500 --out .runtime/stream-500.json
python3 -m backend.stream_replay path/to/corpus-v2.json \
  path/to/report-v2.json --interval-ms 250 --out .runtime/stream-250.json

swiftc -parse-as-library ios/Signloop/Recognition.swift \
  ios/Tests/StreamingReplay.swift -o .runtime/streaming-replay
.runtime/streaming-replay .runtime/stream-1000.json
.runtime/streaming-replay .runtime/stream-500.json
.runtime/streaming-replay .runtime/stream-250.json
python3 -m unittest backend.test_stream_replay -v
```

The CLI checks the original corpus/model-bound calibration report and only
prints aggregate metrics. It does not recalibrate or mutate app settings.

## What this changes about the plan

Simply making Jev calls faster or deleting confirmation is not a validated fix.
Multi-sign inference needs a fast local temporal path, calibrated against
rolling windows and both kinds of false acceptance, then evaluation with
consented continuous phone recordings and fresh signers. A remote model may
help resolve segmented uncertain candidates, but should not gate each camera
frame. The separately tested offline ILY preview remains the app's default.
