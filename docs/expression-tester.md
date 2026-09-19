# Expression lab

Open the standalone native app and tap the smiling-face button beside the
skeleton inspector. This on-device experiment maps visible movements to five
named presets. It does not estimate internal feelings, interpret ASL grammar,
change captions, or drive the goose/voice adapter. The Expo consumer camera
remains unchanged.

## Try it

1. Install the updated native build through Xcode. A merge does not update an
   existing cable-installed app on a phone.
2. Keep one face in view, facing the camera. Relax your brows and mouth, with
   your eyes naturally open. Tap **Use my relaxed face · 2 s**. This is required:
   the app will not classify against an assumed average face before setup.
3. Try each cue. **All five sliders default to 0.15**, the most sensitive
   setting. Your natural brow height and eye opening are the starting point;
   small eyes do not need to reach a fixed absolute opening.
4. Optionally use **Calibrate … · 2 s** on a cue card while holding a comfortable
   expression. The saved range makes its level relative to that movement.
   **Level** excludes your resting variation, then smooths the remaining change.
   Move a slider right to reduce sensitivity if there are unwanted activations.
5. Smile normally. A smile with upper-lip lift must stay **Joy**, not become
   joy/disgust ambiguity. For disgust, make a non-smiling “ew” scrunch: raise
   your upper lip and slightly narrow your eyes. Lip lift alone is insufficient.
6. Relax between cues. A selected movement must persist for 300 ms. A clearly
   stronger cue can win over a faint secondary movement; comparable cues show
   **Ambiguous**. No qualifying cue shows **No clear cue**. Missing tracking
   shows **No face** or **Signal unavailable**. **Face the camera** means the
   view angle has changed substantially since calibration.
7. Test ordinary signing, ASL questions, talking, blinking, occlusion and head
   turns too. Count missed cues and unwanted activations, not just successful
   poses. These heuristics still need live phone testing.

Your completed numeric profile and slider settings are saved on this phone,
including across app relaunches. The app does not save images, video, individual
landmarks or observation histories. It does not upload the profile. This is one
personal profile, not automatic person identification: **recapture for another
person**, changed lighting or a different setup. Switching between front and
back cameras requires a matching baseline before classification.

Pause, face loss, dismissal, switching cameras and stale frames clear the active
result and interrupt unfinished captures while keeping the completed profile.
**Forget my face & reset sensitivity** deletes the saved profile and restores
0.15 defaults. Recapturing neutral clears old cue ranges but keeps slider edits.

## Measurements

| Preset | Movement | Measurement |
| --- | --- | --- |
| Joy | Smile | Mean mouthSmileLeft / mouthSmileRight, relative to own neutral |
| Anger | Lowered brows | Decrease in brow height above the eye-corner line, relative to own neutral |
| Fear | Wide eyes | Increased eyelid gap / eye width, relative to own neutral |
| Sadness | Raised inner brows | Increased inner-versus-outer brow height, relative to own neutral |
| Disgust | Non-smiling scrunch | Upper-lip lift AND slightly narrowed, open eyes, with smile exclusion |

Brow/eye geometry uses explicit MediaPipe landmark IDs. Distances use image
pixels before normalization, so portrait x/y scale differences do not distort
ratios. Each eye uses two eyelid gaps; both eyes are averaged. Brow height uses
the eye corners as its reference, not a moving eyelid. Sadness uses inner versus
outer brow height, so lifting the whole brow is not itself the sadness cue.
Ratios handle image scale and head roll; a coarse nose-to-eye position check
abstains on large changes in view angle. This is not full 3D pose compensation.

The implementation no longer depends on eyeWide or browDown blendshape output.
It also does not substitute noseSneer for upper-lip lift: flat noseSneer output
has been reported in MediaPipe. The new disgust rule is a deliberately simple
scrunch proxy, not a measurement of actual nose wrinkles. The added eye and
smile conditions address the observed overlap with smiling.

## Rules and calibration

`ExpressionMeasurements.swift` extracts measurements from the existing fresh
`SkeletonFrame`. `ExpressionCues.swift` contains the deterministic state machine
and versioned numeric profile store. No model retraining or new camera pipeline
is involved.

- **Neutral capture:** two seconds, at least eight fresh observations, at most
  120 stored samples per measurement. Median neutral plus 1.5 × (90th percentile
  − median) forms the resting dead zone, subject to small measurement-specific
  floors. Negative eye-opening changes from an ordinary blink do not enlarge
  the eye-wide dead zone. Large head or expression changes reject the capture
  and preserve the previous profile.
- **Personal range:** optionally capture a steady comfortable cue for two
  seconds. Its 10th percentile must clear the neutral dead zone by a minimum
  margin; the median becomes the endpoint. Flat/noisy captures do not overwrite
  a usable range. Disgust capture additionally requires its non-smiling scrunch
  conditions in at least 80% of samples.
- **Normalization:** clamp (measurement − neutral − dead zone) / range to 0–1.
  Without a cue capture, default ranges are 0.40 for smile, 0.12 for lowered
  brows, 0.10 for inner-brow slope and 0.20 for upper-lip lift. The eye range is
  25% of the person's neutral eye-opening ratio, with a 0.02 floor.
- **Smoothing/hold:** 120 ms exponential smoothing and 300 ms of fresh qualifying
  observations before activation. Release occurs below 75% of the slider value.
- **Disgust exclusion:** the eyes must narrow beyond the larger of the eye dead
  zone or 6% of neutral, while remaining at least 55% open. Both instantaneous
  and smoothed smile levels must be below 0.10. Failed conditions immediately
  clear disgust's level; lip movement cannot linger into a smile as disgust.
- **Conflict:** among qualifying cues, the strongest may win if it exceeds the
  runner-up by at least 0.20 and is at least 1.8 times its level. Otherwise
  abstain. These are heuristic movement margins, not emotion confidence.
- **Freshness:** missing/invalid landmarks or required bilateral mouth channels
  invalidate readings; no missing side is replaced with zero. Duplicate frames
  do not advance timers. Backward timestamps invalidate readings; gaps over
  400 ms restart holds and abort captures.
- **Persistence:** save completed profiles and slider edits only, never every
  frame. Validate schema, finite values, completeness, camera and ranges on
  load. Invalid/unknown profiles require new setup. Reset removes the stored key.

The dead zone is applied before the sensitive threshold. Lowering a slider does
not amplify measured neutral variation into multiple full-strength cues.

## Checks

Run `bash ios/scripts/test-core.sh` for deterministic coverage of personal
neutral, aspect/scale/roll geometry, small-eye widening, raised-brow neutral,
smile/scrunch separation, weak versus strong conflicts, noise, blinking,
calibration quality, invalid data, timing, hysteresis, camera changes, persistence
and reset. UI tests cover no-face behavior, disabled capture, threshold editing,
relaunch persistence, reset and privacy copy. Synthetic geometry and simulator
checks do not establish live facial-cue accuracy.

For phone testing, capture your neutral once, then try all five movements and
ordinary signing. Check neutral stays clear after closing and reopening the app.
Test in a later session too. This prototype has no recording/export feature.

## Research basis

- [MediaPipe Face Landmarker](https://ai.google.dev/edge/mediapipe/solutions/vision/face_landmarker)
  supplies facial landmarks and blendshape coefficients.
- [MediaPipe FaceMesh topology](https://github.com/google-ai-edge/mediapipe/blob/master/mediapipe/python/solutions/face_mesh_connections.py)
  identifies the eye and brow landmark contours used here.
- [Facial action patterns](https://pmc.ncbi.nlm.nih.gov/articles/PMC3992629/)
  motivate candidate movements, not one-to-one mappings to felt emotions.
- [ASL facial grammar](https://pmc.ncbi.nlm.nih.gov/articles/PMC2632943/)
  explains why lowered brows can be grammatical rather than anger.
- [Reported blendshape limitations](https://github.com/google-ai-edge/mediapipe/issues/5329)
  motivate measuring landmark movement instead of relying on a flat coefficient.
  These are community reports, not a guarantee of behavior on every device.
