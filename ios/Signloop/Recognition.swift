import Foundation

struct Joint: Codable, Equatable {
    let x: Float
    let y: Float
    let z: Float
}

struct TrackedHand: Codable {
    let handedness: String
    let handednessScore: Float // MediaPipe handedness confidence, NOT sign confidence.
    let joints: [Joint]

    /// Wrist-relative, palm-size normalized. Preserves rotation/motion features.
    /// z is MediaPipe's relative depth, not a physical distance.
    var normalized: [Joint] {
        guard joints.count == 21 else { return [] }
        let wrist = joints[0]
        let palm = joints[9]
        let scale = max(sqrt(pow(palm.x - wrist.x, 2) + pow(palm.y - wrist.y, 2)), 0.0001)
        return joints.map { Joint(x: ($0.x - wrist.x) / scale,
                                  y: ($0.y - wrist.y) / scale,
                                  z: ($0.z - wrist.z) / scale) }
    }
}

struct LandmarkFrame: Codable {
    let timestampMS: Int
    let hands: [TrackedHand]
}

struct TemporalBuffer {
    private(set) var frames: [LandmarkFrame] = []
    let durationMS: Int = 2000
    mutating func append(_ frame: LandmarkFrame) {
        frames.append(frame)
        frames.removeAll { $0.timestampMS < frame.timestampMS - durationMS }
        if frames.count > 90 { frames.removeFirst(frames.count - 90) }
    }
    mutating func reset() { frames.removeAll() }
}

struct Classification: Codable {
    struct Candidate: Codable {
        let label: String
        let score: Float
    }
    let candidates: [Candidate]
    let unknown: Bool
    var reason: String? = nil
    var model: String? = nil
}

protocol SignClassifier {
    func classify(frames: [LandmarkFrame]) async throws -> Classification
}

/// Deliberately abstains. Hand tracking does not establish an ASL sign.
/// Replace with your backend client once Jev recognition is validated.
struct UnconfiguredClassifier: SignClassifier {
    func classify(frames: [LandmarkFrame]) async throws -> Classification {
        Classification(candidates: [], unknown: true)
    }
}

/// Aspect-fill mapping shared by portrait video and the joint overlay.
func overlayPoint(_ joint: Joint, sourceWidth: Double, sourceHeight: Double,
                  viewWidth: Double, viewHeight: Double) -> (Double, Double) {
    let scale = max(viewWidth / sourceWidth, viewHeight / sourceHeight)
    return (Double(joint.x) * sourceWidth * scale + (viewWidth - sourceWidth * scale) / 2,
            Double(joint.y) * sourceHeight * scale + (viewHeight - sourceHeight * scale) / 2)
}
