# First real-recording baseline — 2026-09-19

**Conclusion: real matches exist, but this baseline is not ready for the phone.**
Do not describe it as validated ASL recognition.

## Protocol

- Source: official Microsoft ASL Citizen archive, used locally for noncommercial
  research under its [license](https://www.microsoft.com/en-us/research/project/asl-citizen/dataset-license/).
  Original data and derived references are not published.
- Five labels: HELLO, YES, NO, PLEASE, THANK_YOU.
- Deterministic clip selection; official signer-disjoint splits.
- Same pinned MediaPipe 0.10.21 / float16-v1 hand model as the app. Desktop video
  processing, mirrored frames, aspect correction, fixed center <=3-second crop,
  15 Hz extraction, no-hand edge trimming.
- Selected 107 clips; 11 unusable training clips excluded before matching.
- 19 training references from 13 signers; calibration: 32 clips / 4 signers;
  test: 45 clips / 11 different signers.
- Calibration chose maximum DTW distance **0.4**, minimum relative lead **0.1**.
  Neither was selected using test predictions.
- Corpus SHA-256:
  `87f577084535d8ffa6666a7e331f5cc1a667cb52193bfd260abf3847ac3a9010`.

## Held-out results

| Ground truth | Correct | Rejected as Unknown | Wrong label |
| --- | ---: | ---: | ---: |
| HELLO | 0/6 | 6 | 0 |
| YES | 1/6 | 5 | 0 |
| NO | 4/6 | 1 | 1 (YES) |
| PLEASE | 4/6 | 2 | 0 |
| THANK_YOU | 0/6 | 6 | 0 |
| Unsupported signs | 15/15 rejected | 15 | 0 |

- Supported-sign end-to-end accuracy: **9/30 = 30%**.
- Nearest label before distance/margin rejection: **11/30 = 36.7%**.
- Accepted-output precision: **9/10 = 90%**, with very low coverage **10/45**.
- Unsupported false accepts: **0/15**, a small sample, not an assurance.
- Mean local classification time: **13.9 ms** per test window, including fast
  quality rejections. No API/model calls; not a phone camera-to-caption latency.

Calibration recognized 9/17 supported clips and rejected all 15 unsupported clips.
The drop on unseen signers is important; calibration performance is not the result.

## Why so many Unknowns?

Twenty test clips failed the observation-quality gates:

- **17** contained at least one frame with two detections assigned the same
  handedness. V1 refuses ambiguous hand-slot identity for the entire clip.
- **2** had degenerate or insufficient tracked hands.
- **1** had fewer than six tracked frames.

The 17 duplicate-handedness cases comprise 4 HELLO, 1 YES, 1 PLEASE,
1 THANK_YOU, and 10 unsupported clips. Thus only **5 of the 15 unsupported
clips actually reached distance-based matching**. Rejection performance must not
be confused with robust recognition of everyday nonsigning.

The gate is conservative but too brittle. A next version should track hand
identity over time and tolerate brief ambiguous frames, rather than arbitrarily
assigning the same-side hands or silently overwriting one. Diagnostics now expose
`ambiguous_hand_identity`, `insufficient_frames`, and missing/degenerate tracking.
This diagnostic addition does not change any classification decisions above.

Not all failures are from this gate: four usable THANK_YOU clips were still
rejected, and one NO was misclassified as YES. Better hand assignment alone does
not establish a working recognizer. Body-relative context and reliable labeled
references remain important.

## Next experiment

1. Fix hand-track association using training/calibration observations only.
2. Obtain consented/distributable reference recordings from the actual iPhone.
   Research-only ASL Citizen references must not ship in the app or go to Jev.
3. Test true 1.2-second rolling windows, transitions, nonsigning movements and
   the two-consecutive-results UI filter. Isolated trimmed clips are easier.
4. Use fresh held-out recordings/signers for the next accuracy claim. This first
   test set is now inspected development evidence, not an untouched future test.

No phone deployment, provider request, server switch, or transcription was done
for this benchmark. See [reproduction instructions](recognition-evaluation.md).
