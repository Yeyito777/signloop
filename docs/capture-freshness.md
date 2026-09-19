# Capture-time freshness, not processing-time freshness

Previously a frame received its timestamp when the camera queue started
processing it. A delayed sample could therefore appear current, and queue
jitter could distort sign motion timing even though late frames were discarded
by AVCaptureVideoDataOutput where possible.

Build 9 uses the sample buffer's presentation timestamp:

1. Convert from `AVCaptureSession.synchronizationClock` to CoreMedia's host
   clock with `CMSyncConvertTime`. Apple's capture-session header specifies
   that all output sample timestamps use this synchronization clock.
2. Reject missing/invalid clocks, nonfinite/negative/future timestamps, frames
   older than 400ms and nonincreasing timestamps. Do not clamp bad timestamps
   into a fictitious valid stream.
3. After start/resume or camera replacement, require capture time at or after
   the new session epoch. An old queued frame cannot acquire the new camera's
   generation merely because its callback runs later.
4. Pace hand inference using capture time rather than arrival time. Use the
   same host clock for camera UI expiry and the local sign worker's freshness
   checks. Recheck age after inference and delivery to the main thread.

Rejected frames clear displayed signs/landmarks and the sign window, rather
than leaving a misleading result. The existing one-worker/no-backlog and
generation guards remain unchanged.

Settings now exposes **Camera frame age**: capture-to-main-thread delivery at
the last accepted tracking update, including camera/queue/tracking overhead.
It is not camera-to-caption latency and not a constantly incrementing timer.
The value becomes unavailable after expiry. The existing tracking/model
metrics continue to measure their respective processing durations.

## Validation boundaries

Core tests exercise old/pre-switch/duplicate/reordered/future/invalid samples,
recovery without poisoned state, numeric millisecond overflow guards, actual
CoreMedia host-clock identity conversion, and missing/invalid clocks.
A virtual 60s / 30Hz stream with 0–79ms delivery jitter retains 1440 admissions
(24Hz target), without changing capture timestamps.

Signed iPhone compilation verifies AVFoundation/CoreMedia API use. These
tests **do not establish** actual iPhone camera age, clock behavior across
physical camera switches, sustained FPS, or live recognition accuracy.
Those require an unlocked phone and a real camera session.

There is no camera data logging, recording, upload, backend, or API key change.
