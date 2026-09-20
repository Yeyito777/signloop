# Hands + upper body + face, on device

Standalone native build 11 is a tracking/probing foundation, **not ASL recognition**.
Its `SkeletonCameraTracker` replaces the live sign classifier in the native camera
path. The Expo consumer app retains its separate `CameraTracker` gesture flow. No backend or transcription is
started. Existing private research weights, even if present in Documents, are
not loaded by the camera UI.

## Pipeline

Portrait camera BGRA frame → three native Google MediaPipe Tasks 0.10.21
detectors → `SkeletonFrame` → overlay / live inspector / bounded RAM buffer.

| Task | Output used |
| --- | --- |
| Hand Landmarker float16 v1 | Up to two hands, 21 XYZ image landmarks each |
| Pose Landmarker Lite float16 v1 | One person; original indices 0–24, nose through hips |
| Face Landmarker float16 v1 | One face, 478 landmarks including iris, 52 blendshapes |

Facial blendshapes expose brow, eye and mouth movement. They do **not** classify
sentiment, mood, intent or ASL grammar. “Smile” coefficients are muscle/shape
estimates, not evidence that someone is happy. No emotion classifier is used.
MediaPipe body tracking internally predicts the full pose; the app retains and
draws only the upper-body points. Waist/hips may not be visible in close framing.

All tasks run sequentially off the main thread on **the same image and capture
timestamp**, avoiding stale hand/body/face fusion. Target processing cadence is
15 Hz; the camera preview remains independently driven. Late frames are dropped,
not queued. This is a target, not a measured iPhone performance claim.

Camera PTS is converted into the host clock. Results older than 400ms are rejected.
The existing main-thread watchdog clears all geometry and facial coefficients
together (up to one 250ms timer tick after expiry). Pause, camera flip,
interruption and tracking errors invalidate in-flight UI generations and clear
the buffer. Resume/flip recreate detector tracking state.

## Coordinates and association

- Camera buffers are physically portrait-rotated but **never mirrored**.
- All x/y values are normalized to that same image; they may extend beyond its
  bounds. Selfie preview and overlay mirror horizontally exactly once.
- Overlay mapping uses the same aspect-fill crop as the camera preview.
- z is detector-local relative depth, **not shared metric 3D**. Hand, body and
  face z origins/scales must not be treated as a single calibrated skeleton.
- Missing detections are empty arrays, not zero landmarks or carried-over points.
- Pose points with visibility/presence below .5 are not drawn or used for wrist
  association. Missing confidence values are shown as “Not provided”.
- Hands are associated to current usable pose wrists using unique minimum
  image-plane distance (aspect corrected), with .20 image-height unmatched cost
  and .01 cost-separation rejection. This is approximate, not identity tracking.
- Face and pose are independently selected by their detectors. **One person in
  frame only**; there is no validated multi-person identity matching.
- Mint/orange hands mean pose-associated physical left/right, not array order.
  Unassigned hands remain white and still expose all points. Dashed elbow-to-hand
  links are approximate associations; original pose wrists remain available.

## Probe interface

Tap a visible point or use the scope button. The inspector shows current
normalized x/y/z, available confidence fields, selected facial coefficients,
capture timestamp, each detector's inference time, and RAM frame count.
The accessible picker/stepper is an alternative to tapping dense face geometry.
Hand slots are frame-local and can reorder; prefer a pose-matched side when
available. Occluded/missing points show “Not detected”, not frozen coordinates.

`SkeletonFrame` is Codable and contains:

```
schemaVersion, timestampMS, width, height, camera, coordinateSpace
hands[]: points[], modelHandedness, handednessScore, poseSide?
pose[]: original IDs 0...24 + x/y/z + optional visibility/presence
face[]: original IDs 0...477 + x/y/z
expressions: { MediaPipe blendshape name: coefficient }
timingsMS: { hands, pose, face, total }
```

`SkeletonCameraTracker.onSkeletonFrame` is an optional main-thread callback for future
in-process probing. The `probeBuffer` retains at most two seconds / 60 frames.
No live pixel buffers or coordinate files are saved, no automatic export, and
no network consumer is attached. The old remote-recognition adapter is excluded
from the app target. Prior classifier research remains in source, disconnected.

## Models and setup

`bash ios/scripts/bootstrap.sh` obtains and SHA-verifies the official models,
then generates the Xcode project. Models are ignored in Git and bundled by the
local build. No research sign dataset or private sign checkpoint is required.
Existing MediaPipe third-party notices are included.

| Model | SHA-256 |
| --- | --- |
| hand_landmarker.task | `fbc2a30080c3c557093b5ddfc334698132eb341044ccee322ccf8bcf3607cde1` |
| pose_landmarker_lite.task | `59929e1d1ee95287735ddd833b19cf4ac46d29bc7afddbbf6753c459690d574a` |
| face_landmarker.task | `64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff` |

Documentation:
[hands](https://ai.google.dev/edge/mediapipe/solutions/vision/hand_landmarker/ios),
[pose](https://ai.google.dev/edge/mediapipe/solutions/vision/pose_landmarker/ios),
[face](https://ai.google.dev/edge/mediapipe/solutions/vision/face_landmarker/ios).

## Verification and phone check

Core tests cover association order invariance, uncertain/missing wrists,
aspect-fill/mirroring, finite coordinates, buffer bounds/reset and schema
roundtrip, alongside existing capture timestamp/expiry tests.

The simulator-only `--signloop-skeleton-benchmark` launch flag exercises the
actual `SkeletonPipeline` on hash-pinned public MediaPipe `pose.jpg`,
`portrait.jpg` and `thumb_up.jpg`. It verifies expected body, face/blendshape and
hand outputs, timestamp preservation, Codable output and clearing after blank
images. Only aggregate metrics are written to its simulator sandbox.
It never opens a camera and cannot run on a physical phone.

September 19 verification:

- Swift core suite passed, including the new skeleton schema/geometry tests.
- Eight simulator UI tests passed: permission recovery, contrast, persistent
  overlays, all three overlay controls, inspector missing-data state,
  pause/resume, offline privacy and large-text control reachability.
- Actual native pipeline smoke test detected 25 upper-body points in the public
  pose fixture, 478 face points + 52 blendshapes in the portrait fixture, and
  21 hand points in the thumb fixture. Each cleared on subsequent blank input.
- Signed build 11 passed; code signature and three bundled model hashes verified.
  Source and built app scanned for the project's provider/backend secrets: none.
- No phone installation or live camera accuracy/latency claim from these tests.

Before calling live tracking validated, install intentionally and check:

1. Head, both hands and hips in frame; move hands toward forehead and chest.
2. Raise/lower brows, blink, open/close mouth; inspect coefficients without
   interpreting them as emotions or recognized signs.
3. Occlude hands/face and leave frame: no stale overlay or coefficients.
4. Flip camera, pause/resume, background/foreground: aligned fresh skeleton.
5. Use each overlay toggle and probe on both cameras; check selfie mirroring.
6. Sustained frame rate, age, heat and battery on the actual iPhone.

Installation and live phone verification are separate from build/simulator tests.

Deployment update: build 11 was installed and launched on Yeyito on September 19
at 14:19 local time. The user reported that it works. This is positive live
feedback, not a measured sustained latency, landmark-accuracy or ASL benchmark.
