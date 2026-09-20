import Foundation

/// Reuse the SignEngine's time-based segmenter while retaining the complete
/// hand/body observations needed by BasicSignMatcher. No landmarks leave native code.
struct BasicSignSegmentation {
    private var segmenter: SignSegmenter
    private var frames: [SkeletonFrame] = []
    private(set) var attemptStartMS: Int?
    private(set) var startsAttempt = false

    init() {
        var config = SignSegmenter.Config()
        config.lagMS = 200
        segmenter = SignSegmenter(config)
    }

    mutating func reset() {
        segmenter.reset()
        frames.removeAll(keepingCapacity: true)
        attemptStartMS = nil
        startsAttempt = false
    }

    mutating func update(_ frame: SkeletonFrame) -> [SkeletonFrame]? {
        startsAttempt = false
        guard frame.width > 0, frame.height > 0, frame.hasSigningPose else {
            reset()
            return nil
        }
        let hands = frame.hands.compactMap { hand -> TrackedHand? in
            guard let side = hand.poseSide, ["Left", "Right"].contains(side),
                  hand.points.count == 21, hand.points.allSatisfy(\.usable),
                  Set(hand.points.map(\.id)) == Set(0..<21) else { return nil }
            return TrackedHand(handedness: side, handednessScore: hand.handednessScore,
                joints: hand.points.sorted { $0.id < $1.id }.map { Joint(x: $0.x, y: $0.y, z: $0.z) })
        }
        // Keep the live app's immediate tracking-loss invalidation. Completion
        // requires an observed rest/static hold, never missing or stale hands.
        guard !hands.isEmpty else { reset(); return nil }
        if let previous = frames.last,
           frame.timestampMS <= previous.timestampMS || frame.timestampMS - previous.timestampMS > 400 {
            reset()
        }
        frames.append(frame)
        frames.removeAll { $0.timestampMS < frame.timestampMS - 5000 }
        if frames.count > 300 { frames.removeFirst(frames.count - 300) }
        let observation = LandmarkFrame(timestampMS: frame.timestampMS, hands: hands,
            imageAspectRatio: Float(frame.width) / Float(frame.height), mirrored: false)
        let wasArmed = segmenter.armed
        let segment = segmenter.update(observation)
        if attemptStartMS == nil || (!wasArmed && segmenter.armed) {
            startsAttempt = true
            // Keep onset evidence even before the motion threshold is crossed.
            attemptStartMS = attemptStartMS == nil ? frame.timestampMS : frame.timestampMS - 200
        }
        guard let segment else { return nil }
        let start = min(segment.startMS, attemptStartMS ?? segment.startMS)
        let completed = frames.filter { $0.timestampMS >= start && $0.timestampMS <= segment.endMS }
        // Recognition may still be busy. Rearm at the gesture boundary so that
        // collecting the next sign never depends on a worker completing.
        segmenter.finish(frame.timestampMS)
        return completed
    }
}
