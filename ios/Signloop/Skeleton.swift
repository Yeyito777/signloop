import Foundation

/// One observation space, not a reconstructed shared 3D skeleton.
/// x/y: normalized unmirrored portrait image. z: each model's own relative depth.
struct SkeletonPoint: Codable, Equatable {
    let id: Int
    let x: Float
    let y: Float
    let z: Float
    var visibility: Float? = nil
    var presence: Float? = nil

    var usable: Bool {
        x.isFinite && y.isFinite && z.isFinite &&
        (visibility.map { $0.isFinite && $0 >= 0.5 } ?? true) &&
        (presence.map { $0.isFinite && $0 >= 0.5 } ?? true)
    }
}

struct SkeletonHand: Codable {
    let points: [SkeletonPoint]
    let modelHandedness: String
    let handednessScore: Float
    /// Approximate association to this frame's pose wrist, not person identity.
    var poseSide: String? = nil
}

struct SkeletonFrame: Codable {
    var schemaVersion = 1
    let timestampMS: Int
    let width: Int
    let height: Int
    let camera: String
    var coordinateSpace = "unmirrored portrait image; normalized x/y; model-local z, not shared metric depth"
    var hands: [SkeletonHand]
    let pose: [SkeletonPoint] // original MediaPipe IDs 0...24, hips upward
    let face: [SkeletonPoint] // 478, including iris; never filled with stale points
    let expressions: [String: Float] // blendshape coefficients, not emotion probabilities
    let timingsMS: [String: Double]

    var hasPose: Bool { pose.contains { [11, 12].contains($0.id) && $0.usable } }
    var hasFace: Bool { !face.isEmpty }

    func point(_ probe: SkeletonProbe) -> SkeletonPoint? {
        switch probe.part {
        case "pose": return pose.first { $0.id == probe.id && $0.usable }
        case "face": return face.first { $0.id == probe.id && $0.usable }
        case "Left", "Right":
            return hands.first { $0.poseSide == probe.part }?.points.first { $0.id == probe.id && $0.usable }
        case "hand0", "hand1":
            let index = probe.part == "hand0" ? 0 : 1
            return hands.indices.contains(index) ? hands[index].points.first { $0.id == probe.id && $0.usable } : nil
        default: return nil
        }
    }

    /// Unique geometric assignment. Never trust hand-array order or carry an
    /// association across frames. Uncertain wrists remain independent hands.
    mutating func associateHands() {
        for i in hands.indices { hands[i].poseSide = nil }
        guard !hands.isEmpty, hands.count <= 2, width > 0, height > 0 else { return }
        let wrists = [pose.first { $0.id == 15 && $0.usable },
                      pose.first { $0.id == 16 && $0.usable }]
        let aspect = Double(width) / Double(height)
        func distance(_ hand: SkeletonHand, _ side: Int) -> Double {
            guard let a = hand.points.first(where: { $0.id == 0 && $0.usable }),
                  let b = wrists[side] else { return .infinity }
            return hypot(Double(a.x-b.x)*aspect, Double(a.y-b.y))
        }
        // Include unmatched assignments; matching is never forced by missing data.
        let choices = [-1, 0, 1]
        var candidates: [(cost: Double, sides: [Int])] = []
        for a in choices {
            for b in (hands.count == 2 ? choices : [-1]) {
                if a >= 0 && a == b { continue }
                let sides = hands.count == 2 ? [a, b] : [a]
                let cost = sides.enumerated().reduce(0.0) { sum, item in
                    sum + (item.element < 0 ? 0.20 : distance(hands[item.offset], item.element))
                }
                candidates.append((cost, sides))
            }
        }
        candidates.sort { $0.cost < $1.cost }
        guard let best = candidates.first, best.cost.isFinite,
              candidates.count < 2 || candidates[1].cost-best.cost >= 0.01 else { return }
        for (i, side) in best.sides.enumerated() where side >= 0 {
            hands[i].poseSide = side == 0 ? "Left" : "Right"
        }
    }
}

struct SkeletonProbe: Equatable {
    var part: String = "pose"
    var id: Int = 0
    var title: String { "\(part.hasPrefix("hand") ? "Frame-local " : "")\(part.capitalized) · \(id)" }
}

/// A bounded in-memory probe window only. No image storage, disk or transport.
struct SkeletonBuffer {
    private(set) var frames: [SkeletonFrame] = []
    mutating func reset() { frames.removeAll(keepingCapacity: true) }
    mutating func append(_ frame: SkeletonFrame) {
        guard frame.timestampMS >= 0,
              frames.last.map({ frame.timestampMS > $0.timestampMS }) ?? true else { return }
        frames.append(frame)
        frames.removeAll { $0.timestampMS < frame.timestampMS-2000 }
        if frames.count > 60 { frames.removeFirst(frames.count-60) }
    }
}

enum SkeletonGeometry {
    static let poseEdges = [(0, 2), (2, 7), (0, 5), (5, 8), (9, 10),
                            (11, 12), (11, 13), (13, 15), (12, 14), (14, 16),
                            (11, 23), (12, 24), (23, 24)]
    static let handChains = [[0, 1, 2, 3, 4], [0, 5, 6, 7, 8], [5, 9, 10, 11, 12],
                             [9, 13, 14, 15, 16], [13, 17, 18, 19, 20], [0, 17]]
    static func project(_ point: SkeletonPoint, width: Double, height: Double,
                        viewWidth: Double, viewHeight: Double, mirrored: Bool) -> (Double, Double) {
        guard width > 0, height > 0, viewWidth > 0, viewHeight > 0 else { return (0, 0) }
        let scale = max(viewWidth/width, viewHeight/height)
        let x = mirrored ? 1-Double(point.x) : Double(point.x)
        return (x*width*scale-(width*scale-viewWidth)/2,
                Double(point.y)*height*scale-(height*scale-viewHeight)/2)
    }
}
