import Foundation

/// Native reference-dtw-v2 engine. No network, recording, filesystem access or
/// bundled vocabulary. Call from a worker, not the UI/camera capture queue.
/// References must be human-validated and licensed for their intended use.
/// Similarities are exp(-distance), NOT calibrated probabilities.
struct TemporalReferenceMatcher {
    static let modelName = "reference-dtw-v2"

    struct Reference: Codable {
        let id: String
        let label: String
        let frames: [LandmarkFrame]
    }
    struct Match: Codable {
        let label: String
        let referenceID: String
        let distance: Double
        var score: Double { exp(-distance) }
    }
    struct Decision: Codable {
        let candidates: [Match]
        let unknown: Bool
        let reason: String
        let margin: Double
    }
    enum Failure: Error { case invalidFrames, invalidConfiguration, unusableReference }

    private struct Point {
        let x: Double
        let y: Double
        let z: Double
        func distance2D(_ other: Point) -> Double { hypot(x-other.x, y-other.y) }
    }
    private struct Hand {
        let side: Int // Left=0, Right=1, unspecified=-1
        let score: Double
        let xyz: [Point]
        let scale: Double
        let shape: [Double]
        var wrist: Point { xyz[0] }
    }
    private struct Track { let hand: Hand; let timestamp: Int }
    private struct Feature {
        let shape: [Double]
        let motion: Point
    }
    private typealias Step = [Feature?]
    private struct StoredReference {
        let id: String
        let label: String
        let vector: [Step]
    }
    private let references: [StoredReference]
    let maxDistance: Double
    let minMargin: Double

    init(references: [Reference], maxDistance: Double, minMargin: Double) throws {
        guard maxDistance.isFinite, (0...10).contains(maxDistance),
              minMargin.isFinite, (0...1).contains(minMargin),
              references.count <= 256,
              Set(references.map(\.id)).count == references.count,
              Set(references.map(\.label)).count >= 2,
              references.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 128 &&
                  !$0.label.isEmpty && $0.label.count <= 64 && $0.label != "UNKNOWN" }) else {
            throw Failure.invalidConfiguration
        }
        self.maxDistance = maxDistance
        self.minMargin = minMargin
        self.references = try references.map {
            let (vector, _) = try Self.features($0.frames)
            guard !vector.isEmpty else { throw Failure.unusableReference }
            return StoredReference(id: $0.id, label: $0.label, vector: vector)
        }
    }

    func classify(_ frames: [LandmarkFrame]) throws -> Decision {
        let (query, observationReason) = try Self.features(frames)
        guard !query.isEmpty else {
            return Decision(candidates: [], unknown: true, reason: observationReason, margin: 0)
        }
        var closest: [String: Match] = [:]
        var labelOrder: [String: Int] = [:]
        for reference in references {
            let distance = Self.dtw(query, reference.vector)
            if labelOrder[reference.label] == nil { labelOrder[reference.label] = labelOrder.count }
            if closest[reference.label] == nil || distance < closest[reference.label]!.distance {
                closest[reference.label] = Match(label: reference.label,
                                                referenceID: reference.id, distance: distance)
            }
        }
        let ranked = closest.values.sorted {
            $0.distance == $1.distance ?
                labelOrder[$0.label]! < labelOrder[$1.label]! : $0.distance < $1.distance
        }
        let best = ranked[0].distance
        let second = ranked[1].distance
        let margin = (second-best) / max(second, 1e-9)
        let accepted = best <= maxDistance && margin >= minMargin
        return Decision(candidates: ranked, unknown: !accepted,
                        reason: accepted ? "reference_match" :
                            (best > maxDistance ? "too_distant" : "ambiguous"),
                        margin: margin)
    }

    private static func validate(_ frames: [LandmarkFrame]) throws {
        guard frames.count <= 90 else { throw Failure.invalidFrames }
        var last = -1
        for frame in frames {
            let aspect = Double(frame.imageAspectRatio ?? 1)
            guard frame.timestampMS > last, frame.timestampMS < 1_000_000_000_000_000,
                  aspect.isFinite, (0.1...10).contains(aspect), frame.hands.count <= 2 else {
                throw Failure.invalidFrames
            }
            last = frame.timestampMS
            for hand in frame.hands {
                guard ["Left", "Right", "Hand"].contains(hand.handedness),
                      hand.joints.count == 21,
                      hand.joints.allSatisfy({ p in
                          [p.x, p.y, p.z].allSatisfy { $0.isFinite && abs($0) <= 10 }
                      }) else { throw Failure.invalidFrames }
            }
        }
        if let first = frames.first, let last = frames.last,
           last.timestampMS-first.timestampMS > 3000 { throw Failure.invalidFrames }
    }

    private static func shapeDistance(_ a: Hand, _ b: Hand) -> Double {
        var sum = 0.0
        for i in 0..<63 { let d = a.shape[i]-b.shape[i]; sum += d*d }
        return sqrt(sum / 63)
    }

    /// Associate only observed hands. Never interpolate through occlusion.
    private static func associate(_ frames: [LandmarkFrame]) -> [[Hand?]] {
        var previous: [Int: Track] = [:]
        var tracks: [[Hand?]] = []
        for frame in frames {
            let aspect = Double(frame.imageAspectRatio ?? 1)
            let mirrored = frame.mirrored ?? true
            var detections: [Hand] = []
            for raw in frame.hands {
                var side = raw.handedness == "Left" ? 0 : (raw.handedness == "Right" ? 1 : -1)
                if !mirrored && side >= 0 { side = 1-side }
                let score = raw.handednessScore.isFinite ?
                    min(1, max(0, Double(raw.handednessScore))) : 0.5
                let xyz = raw.joints.map {
                    Point(x: (mirrored ? Double($0.x) : 1-Double($0.x))*aspect,
                          y: Double($0.y), z: Double($0.z)*aspect)
                }
                let wrist = xyz[0]
                let scale = wrist.distance2D(xyz[9])
                if scale < 0.015 { continue }
                let shape = xyz.flatMap {
                    [($0.x-wrist.x)/scale, ($0.y-wrist.y)/scale, ($0.z-wrist.z)/scale]
                }
                detections.append(Hand(side: side, score: score, xyz: xyz, scale: scale, shape: shape))
            }
            // Stable sorting also preserves Python's detection-order tie break.
            detections = detections.enumerated().sorted { a, b in
                if a.element.score != b.element.score { return a.element.score > b.element.score }
                if a.element.wrist.x != b.element.wrist.x { return a.element.wrist.x < b.element.wrist.x }
                return a.offset < b.offset
            }.map(\.element)
            if detections.count == 2 {
                let a = detections[0], b = detections[1]
                if a.wrist.distance2D(b.wrist) / ((a.scale+b.scale)/2) < 0.25 &&
                    shapeDistance(a, b) < 0.15 { detections.removeLast() }
            }
            previous = previous.filter { frame.timestampMS-$0.value.timestamp <= 300 }
            func cost(_ hand: Hand, _ side: Int) -> Double {
                let labelCost = hand.side == side ? 0 : 0.35*hand.score
                guard let old = previous[side]?.hand else { return 2.5+labelCost }
                let motion = old.wrist.distance2D(hand.wrist) / ((old.scale+hand.scale)/2)
                return min(motion, 6) + 0.25*shapeDistance(old, hand) + labelCost
            }
            var assigned: [Hand?] = [nil, nil]
            if !detections.isEmpty {
                let orders = detections.count == 1 ? [[0], [1]] : [[0, 1], [1, 0]]
                let costs = orders.map { order in
                    zip(detections, order).reduce(0.0) { $0 + cost($1.0, $1.1) }
                }
                if abs(costs[0]-costs[1]) >= 0.025 {
                    let winner = costs[0] < costs[1] ? 0 : 1
                    for (hand, side) in zip(detections, orders[winner]) {
                        previous[side] = Track(hand: hand, timestamp: frame.timestampMS)
                        assigned[side] = hand
                    }
                }
            }
            tracks.append(assigned)
        }
        return tracks
    }

    private static func features(_ frames: [LandmarkFrame]) throws -> ([Step], String) {
        try validate(frames)
        let tracks = associate(frames)
        // Python V2 validates the canonicalized coordinates again.
        guard tracks.allSatisfy({ step in
            step.compactMap { $0 }.allSatisfy { h in
                h.xyz.allSatisfy { abs($0.x) <= 10 && abs($0.y) <= 10 && abs($0.z) <= 10 }
            }
        }) else { throw Failure.invalidFrames }
        guard let last = tracks.last, last.contains(where: { $0 != nil }) else {
            return ([], frames.last?.hands.isEmpty == false ? "unresolved_hand_tracking" : "no_hands")
        }
        guard frames.count >= 6 else { return ([], "insufficient_frames") }
        let present = tracks.filter { $0.contains(where: { $0 != nil }) }
        guard Double(present.count) >= 0.7*Double(tracks.count) else {
            return ([], "degenerate_or_missing_tracking")
        }
        let scales = tracks.flatMap { $0.compactMap { $0?.scale } }.sorted()
        let middle = scales.count/2
        let scale = scales.count % 2 == 1 ? scales[middle] : (scales[middle-1]+scales[middle])/2
        let origin = present[0].compactMap { $0 }.first!.wrist
        let start = frames[0].timestampMS, end = frames[frames.count-1].timestampMS
        var indices = Set<Int>()
        for k in 0..<24 {
            let target = Double(start) + Double(end-start)*Double(k)/23
            var closest = 0
            for i in 1..<frames.count {
                if abs(Double(frames[i].timestampMS)-target) <
                    abs(Double(frames[closest].timestampMS)-target) { closest = i }
            }
            indices.insert(closest)
        }
        let result: [Step] = indices.sorted().map { i in
            tracks[i].map { hand in
                hand.map { h in
                    Feature(shape: h.shape, motion: Point(x: (h.wrist.x-origin.x)/scale,
                                                         y: (h.wrist.y-origin.y)/scale, z: 0))
                }
            }
        }
        return (result, "usable")
    }

    private static func frameDistance(_ a: Step, _ b: Step) -> Double {
        var total = 0.0, active = 0
        for side in 0..<2 {
            if a[side] == nil && b[side] == nil { continue }
            active += 1
            guard let x = a[side], let y = b[side] else { total += 2; continue }
            var shapeSum = 0.0
            for i in 0..<63 { let d = x.shape[i]-y.shape[i]; shapeSum += d*d }
            total += 0.75*sqrt(shapeSum/63) + 0.25*x.motion.distance2D(y.motion)
        }
        return active > 0 ? total/Double(active) : 1
    }

    private static func dtw(_ a: [Step], _ b: [Step]) -> Double {
        let n = a.count, m = b.count
        let band = max(abs(n-m), Int(ceil(Double(max(n, m))*0.25)))
        var previous = Array(repeating: (cost: Double.infinity, steps: 0), count: m+1)
        previous[0] = (0, 0)
        for i in 1...n {
            var current = Array(repeating: (cost: Double.infinity, steps: 0), count: m+1)
            for j in max(1, i-band)...min(m, i+band) {
                // Equal-cost ties retain Python's up, left, diagonal order.
                var best = previous[j]
                if current[j-1].cost < best.cost { best = current[j-1] }
                if previous[j-1].cost < best.cost { best = previous[j-1] }
                current[j] = (best.cost+frameDistance(a[i-1], b[j-1]), best.steps+1)
            }
            previous = current
        }
        return previous[m].cost/Double(previous[m].steps)
    }
}

/// Replaceable app-facing adapter. Not selected by the UI until an appropriate
/// reference set and rolling-window rejection policy have been validated.
struct NativeTemporalClassifier: SignClassifier {
    let matcher: TemporalReferenceMatcher

    func classify(frames: [LandmarkFrame]) async throws -> Classification {
        let decision = try matcher.classify(frames)
        return Classification(candidates: decision.candidates.map {
            Classification.Candidate(label: $0.label, score: Float($0.score))
        }, unknown: decision.unknown, reason: decision.reason, model: TemporalReferenceMatcher.modelName)
    }
}
