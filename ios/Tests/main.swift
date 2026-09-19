import Foundation

func expect(_ condition: Bool, _ message: String) {
    guard condition else { fatalError("FAIL: \(message)") }
    print("PASS: \(message)")
}

let ily = LocalHandGesture(label: "ILoveYou", score: 0.95, runner: 0.03)
var local = LocalGestureFilter()
expect(local.update([ily], timestampMS: 0) == nil, "Local gesture waits for temporal evidence")
expect(local.update([ily], timestampMS: 75) == nil, "Local gesture requires minimum hold duration")
expect(local.update([ily], timestampMS: 150) == "I_LOVE_YOU", "Stable ILY handshape is accepted locally")
expect(local.update([], timestampMS: 180) == nil, "No hands immediately clears local gesture")
for label in ["Thumb_Up", "Closed_Fist", "Open_Palm", "Victory", "Pointing_Up", "None"] {
    local.reset()
    _ = local.update([LocalHandGesture(label: label, score: 1, runner: 0)], timestampMS: 0)
    _ = local.update([LocalHandGesture(label: label, score: 1, runner: 0)], timestampMS: 75)
    expect(local.update([LocalHandGesture(label: label, score: 1, runner: 0)], timestampMS: 150) == nil,
           "Canned \(label) is never relabeled as an ASL sign")
}
local.reset()
_ = local.update([ily], timestampMS: 0)
_ = local.update([ily], timestampMS: 75)
expect(local.update([ily], timestampMS: 400) == nil, "Stalled frame gap resets local evidence")
expect(local.update([ily], timestampMS: 399) == nil, "Nonmonotonic local timestamps reset evidence")
expect(local.update([ily, ily], timestampMS: 450) == nil, "Single-hand model does not infer compound signs")
expect(local.update([LocalHandGesture(label: "ILoveYou", score: .nan, runner: 0)], timestampMS: 500) == nil,
       "Nonfinite local scores are rejected")
expect(local.update([LocalHandGesture(label: "ILoveYou", score: 0.8, runner: 0.1)], timestampMS: 550) == nil,
       "Weak ILY estimates are rejected")
expect(local.update([LocalHandGesture(label: "ILoveYou", score: 0.9, runner: 0.75)], timestampMS: 600) == nil,
       "Ambiguous ILY estimates are rejected")

var points = Array(repeating: Joint(x: 0.5, y: 0.5, z: 0), count: 21)
points[9] = Joint(x: 0.5, y: 0.75, z: 0)
points[8] = Joint(x: 0.75, y: 0.25, z: -0.1)
let hand = TrackedHand(handedness: "Left", handednessScore: 0.9, joints: points)
expect(hand.normalized[0] == Joint(x: 0, y: 0, z: 0), "Normalization anchors the wrist")
expect(hand.normalized[9] == Joint(x: 0, y: 1, z: 0), "Normalization scales by palm size")
expect(hand.normalized[8] == Joint(x: 1, y: -1, z: -0.4), "Normalization preserves relative depth and direction")
let shifted = points.map { Joint(x: $0.x + 0.25, y: $0.y + 0.25, z: $0.z) }
expect(TrackedHand(handedness: "Left", handednessScore: 1, joints: shifted).normalized == hand.normalized,
       "Normalized shape is translation invariant")
expect(TrackedHand(handedness: "Left", handednessScore: 1, joints: []).normalized.isEmpty,
       "Malformed hands are rejected")
expect(TrackedHand(handedness: "Left", handednessScore: 1,
                   joints: Array(repeating: Joint(x: 0, y: 0, z: 0), count: 21)).normalized.allSatisfy { $0.x.isFinite },
       "Degenerate palm doesn't divide by zero")

var buffer = TemporalBuffer()
for timestamp in stride(from: 0, through: 3000, by: 100) {
    buffer.append(LandmarkFrame(timestampMS: timestamp, hands: [hand]))
}
expect(buffer.frames.count == 21 && buffer.frames.first?.timestampMS == 1000, "Two-second sequence evicts old frames")
buffer.append(LandmarkFrame(timestampMS: 3100, hands: []))
expect(buffer.frames.last?.hands.isEmpty == true, "No-hand observations remain in the sequence")
buffer.reset()
expect(buffer.frames.isEmpty, "Pause/camera-switch reset clears the sequence")
for timestamp in 0..<1000 { buffer.append(LandmarkFrame(timestampMS: timestamp, hands: [])) }
expect(buffer.frames.count == 90, "Buffer has a hard memory bound")

let center = overlayPoint(Joint(x: 0.5, y: 0.5, z: 0), sourceWidth: 720, sourceHeight: 1280,
                          viewWidth: 350, viewHeight: 400)
expect(abs(center.0 - 175) < 0.001 && abs(center.1 - 200) < 0.001, "Aspect-fill preserves center")
let corner = overlayPoint(Joint(x: 0, y: 0, z: 0), sourceWidth: 720, sourceHeight: 1280,
                          viewWidth: 350, viewHeight: 400)
expect(abs(corner.0) < 0.001 && corner.1 < 0, "Aspect-fill crops the same axis as preview")
let encoded = try JSONEncoder().encode(LandmarkFrame(timestampMS: 42, hands: [hand]))
let decoded = try JSONDecoder().decode(LandmarkFrame.self, from: encoded)
expect(decoded.hands[0].joints == points, "Landmark JSON round-trips")
print("All recognition/geometry checks passed.")
var live = LiveSignFilter()
expect(live.update("YES") == nil, "Live output waits for two matching estimates")
expect(live.update("YES") == "YES", "Stable matching estimates become visible")
expect(live.update("NO") == nil, "Changed sign clears the previous label immediately")
expect(live.update("NO") == "NO", "New stable sign becomes visible")
expect(live.update(nil) == nil, "Unknown clears output immediately")
expect(live.update("NO") == nil, "Unknown resets stabilization")
live.reset()
expect(live.update("YES") == nil, "Camera/scene reset clears stale estimates")

let capture = CaptureLifecycle()
expect(capture.token == nil, "Camera starts inactive")
let permissionRequest = capture.begin()
expect(capture.accepts(permissionRequest), "Current camera request can start")
capture.end()
expect(!capture.accepts(permissionRequest), "Pause rejects a late permission reply or queued camera start")
expect(capture.token == nil, "Interruption ending after pause cannot restart capture")
let resumed = capture.begin()
expect(resumed != permissionRequest && !capture.accepts(permissionRequest), "Resume rejects old inference publications")
expect(capture.accepts(resumed), "Fresh capture generation is accepted")
let replaced = capture.begin()
expect(!capture.accepts(resumed) && capture.accepts(replaced), "New capture generation supersedes pending work")
