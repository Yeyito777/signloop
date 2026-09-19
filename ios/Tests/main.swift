import Foundation

func expect(_ condition: Bool, _ message: String) {
    guard condition else { fatalError("FAIL: \(message)") }
    print("PASS: \(message)")
}

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
