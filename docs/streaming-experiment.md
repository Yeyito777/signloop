# Streaming ASL from existing pretrained recognizers: what we measured

Hypothesis under test: *isolated-sign recognizers degrade with vocabulary size, but retaining top-k hypotheses
across overlapping windows, fusing several recognizers, and reranking with fast context (Jev) can preserve useful
accuracy on a large vocabulary, without collecting any training data.*

**Verdict, from the numbers below: partially supported, and not in the way the UX wants.**

1. **Accuracy does collapse with vocabulary size.** Best single model (OpenHands SL-GCN), top-1 on 3,916 held-out
   WLASL val clips: 88% (16 signs), 67% (100), 46% (500), 37% (1000), 29% (2000).
2. **The correct sign usually stays in the top-k.** Four-model ensemble: top-5 is 92% at 100 signs, 79% at 500, 63% at
   2000 (top-10: 95 / 86 / 74%). Top-1 to top-5 gap at 500 signs is 27 points. That gap is what temporal and context
   evidence would have to recover.
3. **Temporal windowing from isolated experts does not beat classifying the whole sign.** It costs accuracy unless the
   window is about as long as the training clips (~2 s). At 1.0 s windows, 500-sign ensemble top-1 falls from 52% to
   39%; at 2.0 s it matches (55%).
4. **Ensembling helps; simple beats clever.** Geometric-mean fusion of four models beats the best single model by
   6 to 7 points at 500 signs. Majority vote, accuracy weights and per-class reliability did not beat plain fusion.
5. **Jev context helps only a little, and only when the prompt lets it.** With a "visual evidence is primary" prompt it
   *hurt* (1 rescued, 6 harmed) and ignored context entirely. With a balanced prompt: +3.7 points (12 rescued, 6
   harmed) on 162 simulated-sentence words, and the shuffled-context control shows no gain (-0.6), so the gain is
   real context, but it is **not statistically significant** and closes only ~4 of the ~33 points between top-1 and
   the top-5 ceiling.
6. **"Tentative English almost immediately" is limited by evidence, not compute.** Inference takes 1 to 47 ms per
   window, but the models need ~1.5 to 2 s of a sign before they are usable (500 signs, top-1 by elapsed time:
   0.5 s = 3%, 1.0 s = 21%, 1.5 s = 39%, 2.0 s = 46%).
7. **The end-to-end demo works mechanically and fails linguistically.** Concurrent pipeline, live Jev calls, X-Ray view:
   `I WANT WATER` produced `SECRET THAT SECRET WANT WATER` (2 of 3 signs right, spurious commits on the first). Kept
   in the logs, not cherry-picked.

## What is real, experimental, simulated, unsupported

| Thing | Status |
| --- | --- |
| Four OpenHands WLASL2000 recognizers (BiLSTM, BERT, ST-GCN, SL-GCN) running real inference on real pose data | **Real** |
| Vocabulary scaling, window study, fusion, prefix (earliness), resolver, resource numbers | **Real measurements**, on WLASL pose clips (see caveats) |
| Overlapping-window concurrent session, deterministic resolver, X-Ray view, randomized trial runner | **Real code, real inference**; unit-tested (12 tests, test doubles used only in tests) |
| Jev reranking | **Real live calls** to Jev via the Backboard gateway; ~0.7 s per call |
| "Sentences" in the context experiment | **Simulated**: hand-authored word order, each word a real isolated clip. Not continuous ASL. |
| "Stream" in the X-Ray demo | **Simulated live**: isolated clips joined back to back, no camera |
| Live camera on iPhone with any of these models | **Unsupported / not built** (see mobile section) |
| Mac webcam capture (`capture_poses.py`) | **Written, not exercised** with a camera |
| ASL Citizen provider | **Wrapper written, not run** (needs licensed dataset metadata) |
| Signer independence | **Not established.** WLASL splits share signers across train/val/test. |
| Anything shippable | **No.** See licensing. |

Evaluation hygiene: OpenHands chose its checkpoints by accuracy on the WLASL **test** split, so test numbers are
optimistic. All headline numbers use the **val** split (never used to train or select). Test is reported alongside; it
is almost identical, so the selection effect here is small.

## The three sources compared

| | ASL Citizen (Microsoft) | WLASL | OpenHands (AI4Bharat) |
| --- | --- | --- | --- |
| What it is | 84k videos, 2,731 signs, 52 Deaf signers, crowd-recorded | ~21k web-scraped videos, 2,000 signs | Pose-based toolkit; pretrained models on 8+ datasets incl. WLASL |
| Pretrained weights | ST-GCN (29 MB), I3D (56 MB) in GitHub release `checkpoints_v1` | I3D, Pose-TGCN via Google Drive links | **BiLSTM, BERT, SL-GCN, ST-GCN on WLASL2000** in release `checkpoints_v1` (14 to 45 MB) |
| Input | Holistic pose (27 pts) or video | video / pose | Holistic pose (27 pts) |
| Usable without collecting data? | Yes for weights; **evaluation data needs the license click-through** and gloss order comes from the licensed metadata | Weights yes; raw videos partly dead links | **Yes**: weights + pre-extracted WLASL pose set (Zenodo, 1 GB), no video needed |
| Status here | Wrapper only | Not used directly (OpenHands covers WLASL) | **Four recognizers running** |

ASL Citizen and OpenHands share the same 27-keypoint pose subset (nose, eyes, shoulders, elbows, both hands), so one
window feeds both. The other engineer's ASL Citizen work can drop in behind the same `RecognitionProvider`.

## Exact checkpoints used (all unmodified)

| Provider | Params | File | SHA-256 (zip) |
| --- | --- | --- | --- |
| BiLSTM | 1.29 M | `wlasl_lstm.zip` (`epoch=109`) | `edcd0e58456dd06d763631f12b25dccaa0ab199a4fbb13b4b70728d6fe5ffc6c` |
| BERT (3 layers) | 2.10 M | `wlasl_bert.zip` (`epoch=392`) | `7bcb942d29b2c9f1d3426350eca0d5b16725e6df46e370db24e29b08125c4d09` |
| ST-GCN | 3.60 M | `wlasl_stgcn.zip` (`epoch=212`) | `01f0c5da855cbdda429725db2f2254d225baae01117a2da46483fbcac9b313f7` |
| SL-GCN | 5.15 M | `wlasl_slgcn.zip` (`epoch=169`) | `b37b8412d2577e30956fb8deb939091d493cad80c2936f8770b0f1cb9714eaf7` |
| Split metadata | | `wlasl_metadata.zip` | `4828ae6b9a630a0169feabc6ab14668e40ea95d477b842b37175e4bd8a16932a` |
| WLASL poses | | Zenodo 6674324 `WLASL.zip` | `0752e9a0bf2b29749a59c0c8d38d16f1413e0331fafa5c7f22a2a1360a9e87b8` |

Source: `https://github.com/AI4Bharat/OpenHands/releases/tag/checkpoints_v1` and `https://zenodo.org/record/6674324`.
ASL Citizen weights (not used): `https://github.com/microsoft/ASL-citizen-code/releases/tag/checkpoints_v1`.
Everything is kept under ignored `.runtime/` and is never bundled.

## Licensing audit (do not treat "downloadable" as "shippable")

| Item | License | Commercial use | Redistribution | Hackathon/research use | Shipping status | Source |
| --- | --- | --- | --- | --- | --- | --- |
| ASL Citizen dataset | Microsoft ASL Citizen Dataset License: "solely for non-commercial, non-revenue generating, research purposes"; delete personal data after research | No | No ("may not distribute the data or your modifications") | Yes, after accepting terms | **Not cleared** | microsoft.com/en-us/research/project/asl-citizen/dataset-license |
| ASL Citizen code | MIT | Yes (code only) | Yes | Yes | Code OK; repo archived | github.com/microsoft/ASL-citizen-code |
| ASL Citizen checkpoints | No separate license stated; trained on the noncommercial data above | **Unresolved** | Unresolved | Yes | **Not cleared** | release `checkpoints_v1` |
| WLASL dataset | Computational Use of Data Agreement (C-UDA-1.0): academic/computational use; commercial use prohibited. Underlying videos are web-scraped from third parties | No | Restricted | Yes | **Not cleared** | dxli94.github.io/WLASL |
| WLASL checkpoints (I3D, Pose-TGCN) | None stated; trained on C-UDA data | Unresolved | Unresolved | Yes | **Not cleared** (not used) | WLASL README (Google Drive) |
| OpenHands code | Apache-2.0 (repo "no longer actively maintained") | Yes (code only) | Yes | Yes | Code OK | github.com/AI4Bharat/OpenHands |
| OpenHands WLASL checkpoints | No separate license stated; trained on WLASL (C-UDA) | **Unresolved; assume no** | Unresolved | Yes | **Not cleared** | release `checkpoints_v1` |
| OpenHands pose data (Zenodo) | Labeled CC BY 4.0 by the uploader, but derived from C-UDA videos and MediaPipe poses of third parties | **Do not assume** | Do not assume | Yes | **Not cleared** | zenodo.org/record/6674324 |

Conclusion: every asset here is fine for a hackathon research experiment with attribution, and **none is cleared to
ship in the app**. A shipping path needs first-party data (see `recognition/collect.py`) or explicit written
permission.

## Architecture (`recognition/stream/`)

```
frames (pose+hands) -> StreamingSession.push_frame()                     never blocks the camera
   -> rolling buffer -> Window every stride (default 0.25 s, width 2.0 s)
   -> window worker: all providers in parallel (thread pool)              RecognitionProvider.infer -> top-k
   -> fusion (geo-mean) -> TemporalResolver  unknown | tentative | stable | committed   (never latched)
   -> ambiguous? -> JevResolver (async, candidates only)                   result ignored if stale
   -> caption: committed words + tentative word  ->  user confirmation -> speech
   X-Ray: snapshot() of all of the above
```

* `provider.py` `Window`, `ProviderResult` (matches the requested JSON), `RecognitionProvider`.
* `openhands_provider.py` four real providers; `asl_citizen_provider.py` refuses to run without licensed assets.
* `temporal.py` windows, aggregators, deterministic resolver. `fusion.py` mean / geo / vote / weighted / class-reliability.
* `context.py` resolver interface: it may rerank or reject the visual candidates, **never invent a word** (a reply
  outside the candidate set is a failed call, tested). Jev sees compact structured state only.
* Local vs remote: all recognition runs locally on this Mac (PyTorch). Only text (candidate labels, probabilities, prior
  words) goes to Jev. No pixels, no landmarks leave the machine.

## Results

### A. Vocabulary scaling (raw whole-clip, WLASL val n=3,916; nested random vocabularies, 5 draws for <2000)

| Vocab | BiLSTM | BERT | ST-GCN | SL-GCN | Ensemble (geo-mean) top-1 / 3 / 5 / 10 |
| --- | --- | --- | --- | --- | --- |
| 16 | 0.57 | 0.74 | 0.75 | 0.88 | 0.88 / 0.97 / 0.97 / 0.99 |
| 100 | 0.33 | 0.54 | 0.52 | 0.67 | 0.73 / 0.88 / 0.92 / 0.95 |
| 500 | 0.16 | 0.35 | 0.33 | 0.46 | 0.53 / 0.73 / 0.79 / 0.86 |
| 1000 | 0.12 | 0.27 | 0.26 | 0.37 | 0.43 / 0.65 / 0.72 / 0.80 |
| 2000 | 0.09 | 0.19 | 0.18 | 0.29 | 0.33 / 0.55 / 0.63 / 0.74 |

(Single-model columns are top-1.) Test split (n=2,878) is within ~1 to 6 points of val everywhere (largest gap at 16 signs). Official WLASL asl100/300/1000
subsets are in `.runtime/stream/scaling.json`. Random-draw std at small vocabularies is in the same file.

### B. Overlapping windows vs whole clip (800 val clips; report fold = 400; 500-sign vocabulary, n=96 in fold)

| Method | top-1 | top-3 | top-5 | top-10 |
| --- | --- | --- | --- | --- |
| Whole clip, ensemble (raw) | 0.522 | 0.711 | 0.764 | 0.833 |
| **W = 1.0 s**, temporal(geo) ensemble | 0.395 | 0.623 | 0.709 | 0.803 |
| **W = 1.5 s**, temporal(geo) ensemble | 0.516 | 0.709 | 0.784 | 0.855 |
| **W = 2.0 s**, temporal(mean) ensemble | **0.546** | 0.720 | 0.792 | 0.857 |
| Single last window, SL-GCN, W = 1.0 / 1.5 / 2.0 | 0.10 / 0.22 / 0.38 | | | |

Aggregators (mean, geometric, max, center-weighted, recency-weighted) differ by only a few points; recency-weighting
is the worst. Fusion variants at the same setting: mean 0.375, geo 0.375, vote 0.375, accuracy-weighted 0.360,
class-reliability 0.360 (W=1.0). Nothing beat plain geometric-mean fusion. Vocab 16 and 100 rows in this experiment have
too few clips (about 25 and 22 in the report fold) to trust; use table A for those sizes. Full tables:
`.runtime/stream/stream*.json`.

### C. How early is the evidence usable? (first t seconds of a clip only; ensemble)

| Elapsed | 0.5 s | 0.75 s | 1.0 s | 1.5 s | 2.0 s | 3.0 s |
| --- | --- | --- | --- | --- | --- | --- |
| 100 signs top-1 / top-5 | .13 / .35 | .29 / .54 | .44 / .71 | .58 / .81 | .65 / .96 | .73 / .96 |
| 500 signs top-1 / top-5 | .03 / .11 | .12 / .30 | .21 / .44 | .39 / .64 | .46 / .74 | .47 / .77 |

The recognizers were trained on whole recorded signs, so partial evidence is out of distribution.

### D. Deterministic resolver (tentative / stable / committed / unknown)

Thresholds tuned on fold A for a target commit precision of 0.80, reported on fold B, W=2.0 s. At 500 signs (n=96):
coverage 26%, commit precision 76%, target not reached on the tuning half; median commit ~2.75 s. At 100 signs (n=22, too
small to rely on): coverage 45%, precision 70%. So the resolver can trade coverage for precision, but at large vocabulary
it mostly declines to commit. It rejects rather than forcing a word, as designed.

### E. Jev contextual reranking (simulated sentences; 162 words; 500-sign vocabulary; top-5 candidates)

| Condition | Visual top-1 | With Jev | Rescued / harmed | UNKNOWN rate |
| --- | --- | --- | --- | --- |
| Prompt "visual primary": own / oracle / shuffled context | 0.537 | 0.506 / 0.506 / 0.506 | 1 / 6 in all three | 9 to 10% |
| Prompt "balanced": own context | 0.537 | **0.574** | 12 / 6 | 0% |
| Prompt "balanced": oracle prior words | 0.537 | 0.568 | 12 / 7 | 0% |
| Prompt "balanced": shuffled prior words (control) | 0.537 | 0.531 | 6 / 7 | 0% |

* Ceiling (truth anywhere in the top-5 candidates): 87%.
* Identical numbers across own/oracle/shuffled under the conservative prompt mean context had no effect: it just
  echoed vision and sometimes said UNKNOWN (which cost 4 correct answers).
* Balanced prompt: +6 net words in 162 (12 vs 6 rescued vs harmed, sign test p about 0.24). Directionally consistent, the
  control passes, but the sample is small and the sentences are short, authored and predictable, i.e. favorable to a
  language model. Real conversation will offer less.
* Latency: 0.63 to 0.85 s median per call (p95 up to 2.8 s), including the network. That is too slow to query every 250 ms
  window; it must be asynchronous and only used on ambiguous decisions, which is how the session uses it.
* No word outside the candidate list was ever accepted (contract enforced and tested).

### F. Latency, memory, mobile feasibility (host Mac, Apple M4; **no iPhone tested**)

Per 2.0 s window, batch 1, fresh process each:

| Provider | CPU p50 / p95 | GPU (MPS) p50 | Batch-64 throughput (CPU) | RSS after load | Load | Core ML |
| --- | --- | --- | --- | --- | --- | --- |
| BiLSTM | 0.9 / 1.2 ms | 2.3 ms | 1,247 win/s | ~500 MB | 3.4 s | **Fails**: `torch.export` cannot trace `LSTM.flatten_parameters` |
| BERT | 4.5 / 4.7 ms | 4.8 ms | 297 | ~525 MB | 3.4 s | Converts (4.3 MB) but **wrong**: 62.5% top-1 agreement even in fp32; do not ship |
| ST-GCN | 13.9 / 15.7 ms | 9.0 ms | 20 | ~540 MB | 3.4 s | Converts (7.3 MB fp16), 97.5% top-1 / 98.5% top-5 agreement |
| SL-GCN | 47 / 56 ms | 27 ms | 27 | ~560 MB | 3.5 s | Converts (14.4 MB fp16), 95% top-1 / 99% top-5 agreement |

RSS includes the PyTorch runtime; the models themselves are 5 to 20 MB. Four providers in parallel cost ~65 ms per
window on CPU, well inside the 250 ms stride. Core ML agreement was measured on 40 real windows with Core ML on the
Mac, not on an iPhone. Input formats: 27 MediaPipe-Holistic keypoints (xy), shoulder-normalized, 2 s at 25 fps (BERT:
subsampled to 120 frames). Fixed frame count needed for Core ML (50).

**The phone gap.** The shipped camera path returns hand landmarks only. These models also need nose, eyes, shoulders and
elbows. Apple Vision's body pose provides those joints on-device and its hand pose gives the 21 hand points, but the
keypoint conventions differ from MediaPipe Holistic (which the models were trained on); that domain shift is untested and
could cost more accuracy than any of the effects above. Until then, run recognition behind the provider boundary on a
Mac/server and label it remote.

### G. Randomized trials (`live_eval.py`, 200 uniformly random signs from a 100-sign vocabulary, WLASL val clips)

Not live people, recorded clips, signers may overlap training. Rank of the target sign:

| | top-1 | top-3 | top-5 | top-10 | absent from top-10 |
| --- | --- | --- | --- | --- | --- |
| BiLSTM | 0.325 | 0.51 | 0.64 | 0.74 | 26% |
| BERT | 0.495 | 0.685 | 0.73 | 0.82 | 18% |
| ST-GCN | 0.50 | 0.685 | 0.79 | 0.86 | 14% |
| SL-GCN | 0.635 | 0.825 | 0.895 | 0.955 | 4.5% |
| Ensemble, whole clip | 0.71 | 0.885 | 0.93 | 0.96 | 4% |
| Ensemble, 2 s overlapping windows | 0.705 | 0.91 | 0.93 | 0.96 | 4% |

Run `--source poses-dir` with `capture_poses.py` recordings to score real new people the same way. That is the measurement
that decides whether this survives contact with users; it has not been run.

### H. End-to-end X-Ray runs (real providers, real Jev, real-time pace, ground truth "I WANT WATER")

* Run 1 (`.runtime/stream/xray_i_want_water_run1_FAILED.txt`): `SECRET THAT SECRET SECRET SECRET`. Two bugs found by the
  X-Ray view: a stale Jev answer was applied to later commits, and the cooldown after a commit was shorter than the 2 s
  window, so one sign re-committed repeatedly. Both fixed (and the fix is tested).
* Run 2 (`xray_i_want_water.txt`): `SECRET THAT SECRET WANT WATER`. WANT and WATER correct; the first sign ("I", a short
  pointing sign) drew three spurious commits. No boundary detector exists yet, so transitions and weak signs commit.

## Why it breaks, and the highest-leverage fix without new data

| Cause | Evidence | Fix that needs no new dataset |
| --- | --- | --- |
| Vocabulary size (classifier confusion) | Table A: top-1 drops ~2x per 5x vocabulary | Restrict candidates by context/task; keep top-k; ensemble (already +6 to 7 points) |
| Window/segment mismatch | Table B: 1.0 s windows lose 13 points; 2.0 s recover them | **Segment whole signs, then classify the whole segment**; reuse `recognition/segmenter.py`. Best accuracy is whole-sign inference. Keep sliding windows only for early tentative display |
| Evidence latency | Table C | Accept ~1.5 to 2 s to first tentative word, or show tentative candidates (top-k) earlier and label them as such |
| Boundary / co-articulation | X-Ray run 2 | Segmenter + refractory; per-sign cooldown (added) |
| Domain shift (phone landmarks vs training) | Not measured | Feed real phone-derived poses through `live_eval.py` before any further claim |
| Signer generalization | WLASL splits share signers | Fresh signers via `capture_poses.py`; this is the missing measurement |
| Context resolver | Table E | Keep it async and gated; treat it as a small booster, not a rescue |

Not tested here, listed as ideas: temperature-scale each provider on val before fusing, test-time augmentation over
crops, class-restricted candidate sets from the app's task.

## Reproduce

```sh
python3.12 -m venv .runtime/venv-oh
.runtime/venv-oh/bin/pip install "torch==2.7.0" numpy omegaconf "transformers<4.50" natsort pandas pyyaml tqdm scikit-learn timm psutil pytorch-lightning coremltools
# download the OpenHands WLASL checkpoints + WLASL.zip into .runtime/oh (URLs above), clone OpenHands into .runtime/oh/repo
.runtime/venv-oh/bin/python -m recognition.stream.exp_scaling --out .runtime/stream/scaling.json
.runtime/venv-oh/bin/python -m recognition.stream.exp_stream  --out .runtime/stream/stream_w2.0.json --width 2.0
.runtime/venv-oh/bin/python -m recognition.stream.exp_prefix  --out .runtime/stream/prefix.json
.runtime/venv-oh/bin/python -m recognition.stream.exp_resolver --vocab 100 500 --width 2.0 --out .runtime/stream/resolver.json
.runtime/venv-oh/bin/python -m recognition.stream.exp_context --vocab 500 --k 5 --style balanced --out .runtime/stream/context.json
.runtime/venv-oh/bin/python -m recognition.stream.bench_resources --out .runtime/stream/resources.json --coreml
.runtime/venv-oh/bin/python -m recognition.stream.live_eval --source wlasl --vocab 100 --trials 200 --out .runtime/stream/trials.jsonl
.runtime/venv-oh/bin/python -m recognition.stream.xray_demo --sentence "i want water" --vocab 500
.runtime/venv-oh/bin/python -m unittest recognition.stream.test_stream
```

Every downstream experiment reads the same cached logits (`.runtime/stream/*.npz`), so results are reproducible without
re-running inference.

## Limits of this study

* Isolated clips, not continuous signing: no co-articulation, no real discourse, no facial grammar, no fingerspelling.
* WLASL is not signer-independent and uses web videos; results will be worse on new people and phone cameras.
* Small samples in places (n=96 or fewer where noted). Context result is not statistically significant.
* Mac numbers only; no iPhone execution.
* The non-manual (face/body) channel is carried in the `Window.extra` slot but no provider consumes it, and no emotion
  labels are produced.
