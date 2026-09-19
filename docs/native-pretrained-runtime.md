# Native pretrained runtime probe — 2026-09-19

The 250-word research candidate now runs through the **actual iOS Swift/C
runtime**, not a Python server. It is still **not selected by the camera UI**.
No pretrained weights, vocabulary, or research observations are in the app
bundle. There is no model download or network call in the engine.

## One inference runtime, not two

MediaPipe TasksCommon 0.10.21 already exports the TensorFlow Lite C API; its
runtime reports **2.18.0**. Linking another TensorFlowLiteC binary would duplicate
213 global symbols and unnecessarily add another runtime.

Instead, bootstrap verifies and installs Google's unchanged TensorFlow Lite
2.17.0 Swift wrapper and C declarations. A header-only module binds to the
existing MediaPipe symbols. All 42 C functions used by that wrapper were found
in the pinned device library. No additional TFLite binary is linked.

- Engine fails closed if the runtime version differs from tested 2.18.0.
- Experimental delegate-option structs are not passed across versions.
- Both model and vocabulary require exact byte length and SHA-256.
- The interpreter uses the **verified bytes**, not a reopened mutable filename.
- A simulator crash exposed borrowed-model-buffer lifetime handling. Fixed by
  retaining immutable model bytes and destroying the interpreter before releasing
  them. The official vendored wrapper remains unchanged.
- On an SDK update, repeat full tensor/logit and hand-model coexistence tests;
  do not assume arbitrary MediaPipe/TFLite combinations are compatible.

## Verified behavior

Pure Swift packing/logit policy matched **117 synthetic cases**, including
missing context, supported/unsupported competition and confidence-cutoff edges.
These synthetic logits/coordinates are not ASL recognition evidence.

The native model was then tested on a disposable **iOS 26.3 simulator on the
development Mac**:

| Probe | Queries | Result |
| --- | ---: | --- |
| Synthetic geometry against Python LiteRT logits | 117, 113 invoking model | All gates, labels, rejection and logits matched |
| Restricted research clips, local simulator only | 61 | All logits/decisions matched |
| Same research probe interleaved with public-image MediaPipe tracking | 61 model calls + 4 hand-model frames | Passed; 21-joint hands still returned |

The final coexistence run had maximum absolute logit difference
**0.000003815** versus Python LiteRT (tolerance 0.001).
Mean native model path was **5.06 ms**, p95 **6.70 ms**, load **14.97 ms**.
Timing includes packing, resizing when needed, invocation and output copy;
excludes camera acquisition, live hand tracking and UI display.
**These are simulator measurements, not iPhone latency or ASL accuracy.**

Both simulator and unsigned iPhone builds passed. All six existing UI tests
(including contrast/accessibility checks), 53 Python tests, the native HTTP
adapter, 124-query native DTW parity, 117-case native pretrained policy contract,
and core Swift checks also passed after the runtime integration.

The model's accuracy/negative-probe limitations and unresolved source-license
discrepancy remain documented in [pretrained research](pretrained-sign-research.md).
The phone was available but passcode-locked at the latest check; no physical
model benchmark has passed, and this task has not replaced its installed app.

## Developer-only entry

Debug launch flag: `--signloop-pretrained-benchmark`.
It reads explicitly provisioned Documents files:

- `model.tflite` and `sign_to_prediction_index_map.json` (exact pinned assets)
- `pretrained-fixture.json`
- `gesture-benchmark.jpg` (Google's public thumb-up test asset)

It writes aggregate `pretrained-benchmark-result.json` with a caller-supplied
`--benchmark-run=...` identifier. Always check that identifier and `passed`;
never mistake an old report for the latest launch. Re-query a simulator's data
container after every install because its path can change.

The screen never opens a camera, captures video or makes network requests.
Release builds ignore the entry flag.

## Reproduce

From the root:

```sh
bash ios/scripts/bootstrap.sh
scripts/dev/signlooptest . native

# In the optional LiteRT research Python environment:
python -m backend.make_pretrained_fixture \
  --model .runtime/model.tflite \
  --vocabulary .runtime/sign_to_prediction_index_map.json \
  --out .runtime/pretrained-fixture.json
```

Provision the synthetic fixture only after inspecting its source marker.
Research fixtures require explicit `--research-corpus ... --local-simulator-only`,
must be written under ignored `.runtime`, and **must never be copied to a phone
or a provider**. The benchmark also refuses their source marker on physical
devices. Keep the existing research-data retention restrictions.

The end-user camera screen and default ILY preview are unchanged.
