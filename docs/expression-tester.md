# Teach once, reuse a fixed demo expression profile

Expression lab is tooling in the standalone native app. The demo experience does
not ask anyone to train or calibrate. A trained profile matches the demonstrator's
saved brow/eye/mouth measurements and stays fixed during normal use.

## On the training phone

1. Install the **Signloop** scheme through Xcode. Build 13's Expression lab says
   **Teach my expressions**; it no longer uses activation sliders as its primary
   recognizer. Merging source does not automatically reinstall a cable-built app.
2. Tap the smile icon, then **Teach my expressions**.
3. Capture your relaxed face, joy, anger, fear, sadness and disgust **twice each**.
   Each button starts a one-second preparation interval and two-second capture.
   Use comfortable, repeatable expressions and keep the camera/head angle steady.
4. Repeat all six once more for checks. These fresh takes test the learned
   examples; they do not alter them. If signals overlap or a take is inconsistent,
   the lab explains what to retake. Neutral changes require a new full setup.
5. Tap **Use this profile for the demo**. The complete checked profile saves
   atomically and becomes active immediately. It loads automatically after the
   app restarts. Closing the lab keeps recognition running on the camera screen.
6. Tap **Export demo profile**, save the JSON through Files, and transfer that
   export to the Mac building the demo. **Import demo profile** can install the
   same checked profile on another training phone without teaching it again.

Setup is never launched automatically. Retraining requires explicitly starting a
replacement in the lab. Cancellation, interruption or a failed save preserves
the installed profile. An unfinished teaching session is temporary and is not
restored after closing the lab/app.

Build 13 makes brow/eye matching more sensitive by default. It can recognize a
softer version of the same taught pattern, so use comfortable movements when
teaching; exaggerated poses are unnecessary. The lab's **Your brow & eye
movement** readout shows change from your relaxed face and percentage of your
own taught change. A raw ratio such as 0.01 can be meaningful; neither it nor
the percentage is a probability. 100% is the captured example, not a required
activation score. Before teaching that expression, only the raw delta appears.

Saved build-12 profiles are preserved. They use the more sensitive matcher if
their saved checks pass it. Otherwise, the original matcher stays active and
the lab explains that teaching a replacement enables the sensitivity update.
New exports include `matchingVersion: 2`; measurement units are unchanged.

This is one person's fixed expression reference. It is not face identification
and does not automatically choose or adapt to other people. These labels describe
deliberate facial movements, not internal feelings or the meaning of ASL signs.

## Bundle the real profile for the demo

The export must come from the actual demonstrator's completed setup. No synthetic
or placeholder profile is shipped in the repository.

```sh
bash ios/scripts/bundle-expression-profile.sh /path/to/DemoExpressionProfile.json
```

The helper validates the full schema, teaching examples and repeat checks before
atomically placing the file at `ios/Signloop/Resources/DemoExpressionProfile.json`.
This personal file is gitignored. Keep the exported original when moving machines
or rebuilding from a clean checkout. Regenerate the Xcode project with
`bash ios/scripts/bootstrap.sh` when adopting this code, then open it and select
**SignloopDemo** with your existing signing team and phone.

The **Demo** configuration:

- Requires a complete validated profile at build time; missing/invalid input
  fails with an actionable error instead of using a fake default.
- Embeds the validated file in the app automatically, even if it was exported
  after the Xcode project was generated.
- Always loads the bundled profile, ignoring leftover local training data.
- Hides the Expression lab entry point and does not show setup or calibration.
- Continues to classify against that profile on every fresh frame, including
  after restart or reinstall. Live camera frames never update it.

The ordinary Signloop training build loads its explicitly saved local profile.
Export/import and teaching controls stay in Expression lab. No images or video
are stored. The export contains numeric feature summaries, variation, camera/view
reference, a profile ID/date and validation summaries. The app never uploads it;
exporting is an explicit action through the system file picker.

The current runtime integration is the standalone native camera app. This does
not add sentiment to the separate Expo Home/Conversation app, captions, speech
or goose adapter. The profile schema and Swift matcher are independent of the
lab UI and can be reused by that integration; use the same measurement version
and camera coordinates rather than interpreting the JSON as emotion probabilities.

## How it works

`ExpressionMeasurements.swift` measures five dimensions from the synchronized
face result: smile, brow height, eye opening, inner-versus-outer brow slope and
upper-lip lift. Eye/brow ratios use aspect-correct image geometry. Missing signals
are never replaced with invented measurements.

`ExpressionTeacher.swift` temporarily collects two separate captures per label.
Each stores a median vector and robust within-take variation (90th–10th percentile
half-range). A take needs at least 12 fresh observations, is capped at 120, and
rejects substantial head movement. Camera changes, missing tracking and gaps over
400 ms abort unfinished takes. A one-second preparation interval is excluded.

`TaughtExpressionModel` scales mouth/brow-slope dimensions by learned range and
variation. For brow height and eye opening, it uses the smallest between-label
difference above measured variation and small geometry noise floors. Thus a
large movement in another expression cannot drown out a repeatable small brow
drop or eye widening. It compares the entire vector
with both examples of all six labels. It rejects near-identical classes,
inconsistent repeated examples and excessive within-take variation. A match must
fall inside a bounded radius relative to the nearest competing expression and
have a clear margin. Anger/fear also compare against the learned direction from
neutral to the taught example at 30–150% strength, with a bounded perpendicular
tolerance. A buffer based on relaxed-face variation suppresses jitter. This is
fixed interpolation of the saved examples; live frames never change the model.
Unknown/intermediate movements can abstain; the model does
not force every frame into an emotion.

This replaces the previous one-cue-per-emotion classifier in the app. A taught
smile may include upper-lip lift and eye narrowing; those become part of its
pattern rather than independently triggering disgust. The existing detector is
not retrained and no cloud model is used. If its measurements cannot distinguish
two poses, setup reports that limitation instead of installing overlapping labels.

Fresh repeat checks must match the expected label on at least 80% of observations,
include a continuous 300 ms match, and match at their median. Only then can the
six-label profile be installed/exported. Runtime also requires a continuous
300 ms match for expression activation. A relaxed-face match clears immediately.
Missing/stale signals, a wrong camera, a substantial view-angle change and unseen
patterns abstain. No threshold sliders or online adaptation alter this profile.

## Validation and limits

`bash ios/scripts/test-core.sh` covers full-pattern matching, same upper-lip
movement in smile/disgust, personal neutral, unknown poses, holds/freshness,
training versus independent checks, conflicting captures, persistence, import
validation, failed saves and bundled-profile precedence. Existing geometry and
native core checks also run. Optional private Core ML fixtures remain separate.
Sensitivity regressions include a 0.01 brow drop, 0.006 eye-opening change,
softer/stronger patterns, reversed/mixed movements, neutral jitter, personal
movement readouts and preservation of valid older profiles.

Simulator UI checks cover lab-only setup, disabled capture without a face,
export requiring a complete profile, cancellation/relaunch, and a dedicated
SignloopDemo check for a loaded bundle with no teaching entry point. Any synthetic
profile used by those checks is only a temporary disposable-simulator fixture.

These checks establish implementation behavior, not recognition accuracy on the
demonstrator. The guided repeat checks use actual camera measurements, but a later
phone session is still needed: try each pose several times, then normal signing,
talking, blinking and transitions. Keep lighting and camera placement close to
the teaching setup. Record unexpected matches and missed expressions manually.

## References

- [MediaPipe Face Landmarker](https://ai.google.dev/edge/mediapipe/solutions/vision/face_landmarker)
- [MediaPipe eye/brow landmark topology](https://github.com/google-ai-edge/mediapipe/blob/master/mediapipe/python/solutions/face_mesh_connections.py)
- [Reported coefficient limitations](https://github.com/google-ai-edge/mediapipe/issues/5329)
- [ASL facial grammar](https://pmc.ncbi.nlm.nih.gov/articles/PMC2632943/)
