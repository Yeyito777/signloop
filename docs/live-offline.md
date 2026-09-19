# Live offline research mode

Camera → MediaPipe hand landmarks → latest 1.2 seconds → 15Hz observed-frame
sampling → native pretrained model → uncertainty/articulation rejection →
two-result confirmation → current possible sign. No backend, Jev, transcription,
network request, recording or reference-capture step.

## Availability

The public checkout bundles **only the official ILY gesture model**. To exercise
the five-sign research worker, a private **Debug** app's Documents directory must
contain the exact pinned `model.tflite` and
`sign_to_prediction_index_map.json` described in
[pretrained research](pretrained-sign-research.md). The initializer checks both
lengths, SHA-256 digests and runtime version before inference.

These assets are **not copied by bootstrap, bundled, committed, downloaded by
the app or silently installed on a phone**. Mirror MIT metadata conflicts with
the original weights' Unknown metadata; do not represent distribution rights as
resolved. Release builds do not load private Documents models.

When both assets validate, opening the app automatically enables
HELLO / YES / NO / PLEASE / THANK_YOU, plus the separate ILY handshape path.
No on-phone configuration is needed. The scope banner says
“Offline research preview · 5 signs + ILY”. Without assets it truthfully says
“Offline preview · ILY handshape only”. Partial or invalid files fail closed,
with an explanation in Settings. Relaunch after developer provisioning.

No ASL Citizen clips/references are needed for this mode and **none should be
installed on a physical phone**. That restricted dataset is only used in the
local Mac simulator research replay.

## Responsiveness and stale-result safety

- MediaPipe stays on the camera queue; learned inference uses a separate serial
  worker. No model call blocks the main UI or hand-tracking queue.
- At most one job outstanding, target cadence 250ms. While it runs, input
  replaces the bounded latest window; no inference backlog is queued.
- Nearest observed-frame sampling targets 15Hz independent of camera FPS.
  No synthetic/interpolated joint coordinates or duplicated observations.
- Input and completed result must be at most 400ms old. The 250ms UI watchdog
  clears a stalled visible result within about 650ms, even if hand tracking
  continues while the learned model hangs.
- Two matching accepted results are required. Unknown clears immediately.
  The [NO articulation guard](recognition-motion-guard.md) is applied.
- Hand loss, tracking gaps, metadata changes, pause, camera switch, background,
  interruption and camera error invalidate pending evidence.
- A generation-tagged camera callback cannot revive frames from before pause
  or camera switch. A superseded model callback releases only its own slot and
  cannot update the new generation. Reset never allows another queued model job.
- The camera screen no longer instantiates `RemoteRecognition`, even if an old
  persisted cloud preference or backend pairing remains on the phone.

This is a **research preview**, not validated continuous ASL translation.
The model lacks face/body input, scores are uncalibrated, and prerecorded
landmarks do not establish real-phone accuracy.

## Tests

`bash ios/scripts/test-core.sh` includes deterministic live scheduling checks:
two-result confirmation, unknown, pause/flip/release/gap generations, duplicate
callbacks, malformed scores, independent model/camera stalls, 10–60 FPS
resampling and a simulated 60-second stream (237 requests, bounded memory).
Native model/tensor/articulation tests are under `signlooptest . native`.

The Debug simulator-only launch flag `--signloop-live-replay` exercises the
actual native classifier and `LiveWindowPolicy` on a local
`live-replay-fixture.json`. It never opens a camera; real measured simulator
compute duration is included in a virtual capture clock. Its source marker must
be `LOCAL_RESEARCH_ONLY_ASL_CITIZEN`; clips contain only `split`, `label`, `frames`.
Output `live-replay-result.json` contains aggregate counts, timing and run ID,
not per-frame coordinates. Inspect `completed` and the exact `--benchmark-run=`
value; an old result file is not evidence of a new successful run.

Only construct this fixture locally from the existing licensed research corpus,
keep it ignored/temporary, and delete the disposable simulator afterward.
Do not send the fixture to providers or a physical phone.

### Native replay observed September 19, 2026

61 local clips, one cold camera-policy run per clip (not three timing phases):

| Split | Supported clips with correct display | Unsupported clips with false display | Any wrong displayed label |
| --- | ---: | ---: | ---: |
| Calibration | 13/17 | 0/15 | 0/32 |
| Previously inspected diagnostic test | 12/14 | 0/15 | 0/29 |

Diagnostic coverage by word: HELLO 2/3, YES 2/2, NO 3/3, PLEASE 2/2,
THANK_YOU 3/4. These small, previously inspected cohorts are not independent
confirmation of live accuracy. This is a different scheduling protocol from
the three-phase Python report; do not compare the percentages as a controlled
improvement.

205 actual native model calls: mean **4.71ms**, p95 **5.78ms** on the Mac's iOS
simulator, not an iPhone measurement and not camera-to-caption latency.
The app's actual asset loader was also exercised: with assets, the UI showed
the five-sign scope; without them, it showed the ILY fallback. No synthetic
recognized caption was injected into the camera UI.

Validation also passed 61 Python tests, core scheduling checks, native
HTTP/DTW/tensor/articulation tests, and six UI tests **both without and with**
private model assets (including permission recovery, contrast, overlays,
pause/resume and large text).

Debug build **6**, source `3411d1f`, was installed on Yeyito's iPhone at
05:34 local time, September 19. The two exact pretrained assets were copied
successfully into its private Documents container. No API keys or research
observations were transferred. The phone was locked at the preceding check;
the launch command failed with a CoreDevice/Mercury connection error.
**Successful installation/provisioning does not establish successful launch,
on-phone model performance or live recognition accuracy.** Unlock and open
Signloop to validate; no Mac or Wi-Fi connection is needed for this mode.
