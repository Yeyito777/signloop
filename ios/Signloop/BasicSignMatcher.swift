import Foundation

/// Small, replaceable, on-device research baseline. All normalization and DTW
/// code is shared by live camera and desktop replay; no mock signs or network.
struct BasicReference: Codable {
    let id: String
    let label: String
    let split: String
    let signer: String
    let frames: [SkeletonFrame]
    var features: [BasicFeature]? = nil
}

struct BasicReferenceBank: Codable {
    let version: Int
    let labels: [String]
    var maxDistance: Float
    var minMargin: Float
    let references: [BasicReference]
    var windowMS: Int? = nil
    var ruleWeight: Float? = nil
    var queryFrames: Int? = nil

    func validate() throws {
        guard (version == 2 || (version == 1 && references.allSatisfy { $0.features == nil })),
              (400...2400).contains(windowMS ?? 1800), [16, 32].contains(labels.count), Set(labels).count == labels.count,
              (ruleWeight ?? 0.2).isFinite, (0...1).contains(ruleWeight ?? 0.2),
              (4...6).contains(queryFrames ?? 4),
              references.count <= 256, !references.isEmpty,
              maxDistance.isFinite, (0...1).contains(maxDistance),
              minMargin.isFinite, (0...1).contains(minMargin),
              Set(references.map(\.id)).count == references.count,
              references.allSatisfy({ $0.split == "train" && labels.contains($0.label)
                  && ($0.features.map { $0.count == 16 && $0.allSatisfy(\.valid) }
                      ?? (!$0.frames.isEmpty && $0.frames.count <= 2000)) }) else {
            throw NSError(domain: "BasicReferenceBank", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid private reference bank"])
        }
    }
}

struct BasicCandidate: Codable {
    var label: String?
    var distance: Float = 999
    var margin: Float = 0
    var scores: [BasicSignScore] = []
}

/// Independent similarity scores, NOT posterior probabilities or confidence.
/// The fixed display scale is unrelated to acceptance thresholds. In particular
/// a high score can still be rejected because competing signs look similar.
struct BasicSignScore: Codable, Identifiable {
    static let vocabulary = ["HELLO", "YES", "NO", "PLEASE", "THANKYOU", "HELP", "WATER", "MORE",
                             "FINISH", "GOOD", "BAD", "NAME", "MY", "SORRY", "STOP", "YOU",
                             "ILOVEYOU", "WE", "OUR", "NICE", "MEET", "TODAY", "PROJECT",
                             "TECHNOLOGY", "COMPUTER", "PHONE", "SIGNLANGUAGE", "UNDERSTAND",
                             "LEARN", "SHOW", "MAKE", "CAMERA"]
    let label: String
    let distance: Float?
    var id: String { label }
    var similarity: Float? {
        guard let distance, distance.isFinite, distance >= 0 else { return nil }
        return exp(-distance / 0.08)
    }
    static func rows(labels: [String], distances: [String: Float] = [:]) -> [BasicSignScore] {
        labels.map { label in
            let d = distances[label]
            return BasicSignScore(label: label, distance: d.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil })
        }
    }
}

struct BasicFeature: Codable {
    // Hand-local XYZ, body image XY. Never mix detector-local depths.
    var hands: [[Float]?]
    var body: [[Float]?]
    var face: [Float]?
    var time: Int
    var motion: [[Float]?]? = nil
    var shape: [[Float]?]? = nil
    var hasHand: Bool { hands.contains { $0 != nil } }
    var valid: Bool {
        hands.count == 2 && body.count == 2 &&
        hands.allSatisfy { $0.map { $0.count == 63 && $0.allSatisfy { $0.isFinite && abs($0) < 100 } } ?? true } &&
        body.allSatisfy { $0.map { $0.count == 4 && $0.allSatisfy { $0.isFinite && abs($0) < 100 } } ?? true } &&
        (face.map { $0.count == 5 && $0.allSatisfy { $0.isFinite && (0...1).contains($0) } } ?? true) &&
        (motion.map { $0.count == 2 && $0.allSatisfy { $0.map { $0.count == 2 && $0.allSatisfy(\.isFinite) } ?? true } } ?? true) &&
        (shape.map { $0.count == 2 && $0.allSatisfy { $0.map { $0.count == 45 && $0.allSatisfy(\.isFinite) } ?? true } } ?? true)
    }

    func mirrored() -> BasicFeature {
        func flip(_ x: [Float]?, stride: Int = 2) -> [Float]? {
            x.map { values in values.enumerated().map { $0.offset % stride == 0 ? -$0.element : $0.element } }
        }
        return BasicFeature(hands: [flip(hands[1], stride: 3), flip(hands[0], stride: 3)],
                            body: [flip(body[1]), flip(body[0])], face: face, time: time,
                            motion: motion.map { [flip($0[1]), flip($0[0])] },
                            shape: shape.map { [$0[1], $0[0]] })
    }
}

final class BasicSignMatcher {
    let bank: BasicReferenceBank
    private var references: [(String, [BasicFeature], [[Float]?])] = []
    private(set) var usableReferenceCount = 0

    init(bank: BasicReferenceBank) throws {
        try bank.validate()
        self.bank = bank
        for reference in bank.references {
            if let sequence = reference.features ?? Self.sequence(reference.frames) {
                let prepared = sequence.map { original -> BasicFeature in
                    var f = original
                    f.shape = f.hands.map { $0.map(Self.intrinsicShape) }
                    return f
                }
                references.append((reference.label, prepared, Self.trajectorySignature(prepared)))
            }
        }
        usableReferenceCount = references.count
    }

    /// Private deployment asset: only the prepared training sequences, not
    /// verbose full-frame geometry, videos, validation or test examples.
    func packedBank() -> BasicReferenceBank {
        let packed = bank.references.compactMap { reference -> BasicReference? in
            guard let features = reference.features ?? Self.sequence(reference.frames) else { return nil }
            return BasicReference(id: reference.id, label: reference.label, split: reference.split,
                                  signer: reference.signer, frames: [], features: features)
        }
        return BasicReferenceBank(version: 2, labels: bank.labels,
                                  maxDistance: bank.maxDistance, minMargin: bank.minMargin,
                                  references: packed, windowMS: bank.windowMS ?? 1800,
                                  ruleWeight: bank.ruleWeight ?? 0.2, queryFrames: bank.queryFrames ?? 4)
    }

    private static func feature(_ frame: SkeletonFrame) -> BasicFeature? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        let aspect = Float(frame.width) / Float(frame.height)
        func xy(_ p: SkeletonPoint) -> [Float] { [p.x * aspect, p.y] }
        func pose(_ id: Int) -> SkeletonPoint? { frame.pose.first { $0.id == id && $0.usable } }
        guard let l = pose(11), let r = pose(12) else { return nil }
        let left = xy(l), right = xy(r)
        let scale = hypot(left[0]-right[0], left[1]-right[1])
        guard scale > 0.035, scale < 2 else { return nil }
        let origin = [(left[0]+right[0])/2, (left[1]+right[1])/2]
        func relative(_ p: SkeletonPoint) -> [Float] {
            [(p.x*aspect-origin[0])/scale, (p.y-origin[1])/scale]
        }
        var hands: [[Float]?] = [nil, nil]
        var body: [[Float]?] = [nil, nil]
        for side in 0..<2 {
            if let wrist = pose(15+side), let elbow = pose(13+side) {
                body[side] = relative(wrist) + relative(elbow)
            }
        }
        for hand in frame.hands.prefix(2) {
            guard hand.points.count == 21,
                  hand.points.allSatisfy(\.usable),
                  Set(hand.points.map(\.id)) == Set(0..<21) else { continue }
            let p = hand.points.sorted { $0.id < $1.id }
            let wrist = xy(p[0])
            // A projected wrist→middle distance collapses when pointing at
            // the camera. Use several palm bones in hand-local 3D instead.
            let lengths = [5, 9, 13, 17].map { i -> Float in
                let dx = (p[i].x-p[0].x)*aspect, dy = p[i].y-p[0].y
                let dz = (p[i].z-p[0].z)*aspect
                return sqrt(dx*dx+dy*dy+dz*dz)
            }.sorted()
            let palm = (lengths[1]+lengths[2])/2
            guard palm > 0.004 else { continue }
            // Physical pose association where available; otherwise infer from
            // the nearest visible pose wrist, not the unstable hand-array slot.
            let side: Int
            if hand.poseSide == "Left" { side = 0 }
            else if hand.poseSide == "Right" { side = 1 }
            else if let a = pose(15), let b = pose(16) {
                let da = hypot(wrist[0]-a.x*aspect, wrist[1]-a.y)
                let db = hypot(wrist[0]-b.x*aspect, wrist[1]-b.y)
                guard abs(da-db) > 0.01 else { continue }
                side = da < db ? 0 : 1
            } else { continue }
            guard hands[side] == nil else { continue }
            hands[side] = p.flatMap { point in
                [(point.x*aspect-wrist[0])/palm, (point.y-wrist[1])/palm,
                 (point.z-p[0].z)*aspect/palm]
            }
            let elbow = pose(13+side).map(relative) ?? relative(p[0])
            body[side] = relative(p[0]) + elbow
        }
        // Nonmanual movement features are low weight; never sentiment labels.
        var face: [Float]?
        if !frame.face.isEmpty {
            let e = frame.expressions
            face = ["jawOpen", "mouthPucker", "browInnerUp"].map { e[$0] ?? 0 }
            face!.append(((e["mouthSmileLeft"] ?? 0)+(e["mouthSmileRight"] ?? 0))/2)
            face!.append(((e["browDownLeft"] ?? 0)+(e["browDownRight"] ?? 0))/2)
        }
        let result = BasicFeature(hands: hands, body: body, face: face, time: frame.timestampMS,
                                 shape: hands.map { $0.map(Self.intrinsicShape) })
        return result.valid ? result : nil
    }

    private static func sequence(_ frames: [SkeletonFrame], minimum: Int = 6) -> [BasicFeature]? {
        let features = frames.compactMap(feature)
        guard features.filter(\.hasHand).count >= minimum,
              let first = features.firstIndex(where: \.hasHand),
              let last = features.lastIndex(where: \.hasHand),
              features[last].time-features[first].time >= (minimum == 6 ? 300 : 180) else { return nil }
        let active = Array(features[first...last])
        // Preserve missing observations inside the gesture. Time-based
        // subsampling removes FPS dependence without inventing coordinates.
        let start = active[0].time, duration = active.last!.time-start
        var result = (0..<16).map { i in
            let time = start + duration*i/15
            return active.min { abs($0.time-time) < abs($1.time-time) }!
        }
        for i in result.indices {
            result[i].motion = (0..<2).map { side -> [Float]? in
                guard i > 0, result[i].hands[side] != nil, result[i-1].hands[side] != nil,
                      let a = result[i-1].body[side], let b = result[i].body[side],
                      result[i].time-result[i-1].time <= 250 else { return nil }
                return [(b[0]-a[0])*4, (b[1]-a[1])*4]
            }
        }
        return result
    }

    private static func cost(_ a: BasicFeature, _ b: BasicFeature) -> Float {
        func compare(_ x: [Float]?, _ y: [Float]?, missing: Float) -> Float {
            switch (x, y) {
            case (nil, nil): return 0
            case (nil, _), (_, nil): return missing
            case let (x?, y?):
                var sum: Float = 0
                for i in x.indices { let delta = x[i]-y[i]; sum += min(delta*delta, 4) }
                return sum / Float(x.count)
            }
        }
        var value: Float = 0
        for side in 0..<2 {
            // Mostly rotation-invariant hand shape, with a smaller orientation
            // term: pointing toward the lens should not destroy shape matching.
            value += 0.3 * compare(a.hands[side], b.hands[side], missing: 0.7)
            value += 0.7 * compare(a.shape?[side], b.shape?[side], missing: 0.7)
            value += 1.5 * compare(a.body[side], b.body[side], missing: 0.5)
            if let x = a.motion?[side], let y = b.motion?[side] {
                value += 0.5 * compare(x, y, missing: 0)
            }
        }
        // Facial grammar is outside this isolated 16-label experiment.
        // Do not make tracking face a runtime requirement for these matches.
        return value / 5
    }

    static func intrinsicShape(_ hand: [Float]) -> [Float] {
        let points = [0, 4, 5, 8, 9, 12, 13, 16, 17, 20]
        guard hand.count == 63 else { return [] }
        var values: [Float] = []
        for i in points.indices {
            for j in (i+1)..<points.count {
                values.append(sqrt((0..<3).reduce(Float(0)) { sum, axis in
                    let d = hand[points[i]*3+axis]-hand[points[j]*3+axis]
                    return sum+d*d
                }))
            }
        }
        return values
    }

    /// Whole-window path evidence cannot be warped into a single static pose.
    /// Absolute extent/arc length distinguishes a hold from circular motion;
    /// endpoints retain direction without requiring a particular circle direction.
    static func trajectoryCost(_ a: [BasicFeature], _ b: [BasicFeature]) -> Float {
        motionDistance(trajectorySignature(a), trajectorySignature(b))
    }

    private static func trajectorySignature(_ frames: [BasicFeature]) -> [[Float]?] {
        func normal(_ hand: [Float]) -> [Float]? {
            let u = (0..<3).map { hand[5*3+$0]-hand[$0] }
            let v = (0..<3).map { hand[17*3+$0]-hand[$0] }
            let n = [u[1]*v[2]-u[2]*v[1], u[2]*v[0]-u[0]*v[2], u[0]*v[1]-u[1]*v[0]]
            let length = sqrt(n.reduce(0) { $0+$1*$1 })
            return length > 0.001 ? n.map { $0/length } : nil
        }
        func signature(_ frames: [BasicFeature], _ side: Int) -> [Float]? {
            let points = frames.enumerated().compactMap { i, f -> (Int, [Float])? in
                guard f.hands[side] != nil, let wrist = f.body[side] else { return nil }
                return (i, wrist)
            }
            guard points.count >= 4 else { return nil }
            var path: Float = 0
            // Ignore small tracking noise; never bridge missing observations.
            for i in 1..<points.count where points[i].0-points[i-1].0 == 1 {
                let p = points[i].1, q = points[i-1].1
                path += max(0, hypot(p[0]-q[0], p[1]-q[1])-0.015)
            }
            let x = points.map { $0.1[0] }, y = points.map { $0.1[1] }
            var angularPath: Float = 0
            for i in 1..<frames.count {
                guard frames[i].time-frames[i-1].time <= 250,
                      let h = frames[i].hands[side], let previous = frames[i-1].hands[side],
                      let a = normal(h), let b = normal(previous) else { continue }
                let dot = zip(a, b).reduce(Float(0)) { $0+$1.0*$1.1 }
                angularPath += min(0.5, max(0, acos(max(-1, min(1, dot)))-0.05))
            }
            return [x.max()!-x.min()!, y.max()!-y.min()!, path*0.5,
                    x.last!-x.first!, y.last!-y.first!, angularPath*0.3]
        }
        return (0..<2).map { signature(frames, $0) }
    }

    private static func motionDistance(_ a: [[Float]?], _ b: [[Float]?]) -> Float {
        var cost: Float = 0
        for side in 0..<2 {
            guard let x = a[side], let y = b[side] else { continue }
            cost += zip(x, y).reduce(Float(0)) { $0 + min(4, ($1.0-$1.1)*($1.0-$1.1)) } / Float(x.count)
        }
        return cost * 0.4
    }

    /// Interpretable, soft anatomical priors, not invented reference sequences.
    /// Ratios are 3D distances within ONE hand, so a camera-facing point does
    /// not become a fist merely because the fingers are foreshortened in XY.
    static func straightness(_ hand: [Float], finger: Int) -> Float {
        guard hand.count == 63, (0..<4).contains(finger) else { return 0 }
        let start = 5 + finger*4
        func distance(_ a: Int, _ b: Int) -> Float {
            sqrt((0..<3).reduce(Float(0)) { sum, j in
                let d = hand[a*3+j]-hand[b*3+j]; return sum+d*d
            })
        }
        let path = (start..<(start+3)).reduce(Float(0)) { $0 + distance($1, $1+1) }
        return path > 0.0001 ? min(1, distance(start, start+3)/path) : 0
    }

    static func anatomicalPenalty(label: String, sequence: [BasicFeature]) -> Float {
        let expected: [Bool?]
        switch label {
        case "ILOVEYOU": expected = [true, false, false, true]
        case "YOU": expected = [true, false, false, false]
        case "WATER": expected = [true, true, true, false]
        case "NAME": expected = [true, true, false, false]
        case "NO": expected = [true, true, nil, nil]
        case "YES", "SORRY": expected = [false, false, false, false]
        case "HELLO", "MY", "PLEASE", "THANKYOU", "GOOD", "BAD", "STOP", "FINISH":
            expected = [true, true, true, true]
        case "HELP": expected = [false, false, false, false] // active thumbs-up fist
        case "MORE": expected = []
        default: return 0
        }
        var costs: [Float] = []
        for frame in sequence {
            let hands = frame.hands.compactMap { $0 }
            let values = hands.map { hand -> Float in
                if label == "MORE" {
                    let tips = [4, 8, 12, 16, 20]
                    var spread: Float = 0
                    for tip in tips.dropFirst() {
                        spread += sqrt((0..<3).reduce(Float(0)) { sum, j in
                            let d = hand[tip*3+j]-hand[4*3+j]; return sum+d*d
                        })
                    }
                    return min(1, pow(max(0, spread/4-0.5), 2))
                }
                var value: Float = 0
                for i in expected.indices {
                    guard let extended = expected[i] else { continue }
                    let ratio = straightness(hand, finger: i)
                    let violation = extended ? max(0, 0.8-ratio)/0.4 : max(0, ratio-0.65)/0.35
                    value += min(1, violation*violation)
                }
                return value / Float(expected.compactMap { $0 }.count)
            }
            if let best = values.min() { costs.append(best) }
        }
        guard !costs.isEmpty else { return 0 }
        // Gestures can change shape during execution: do not demand a held
        // handshape on every frame or count a missing hand as contradictory.
        let phase = costs.sorted().prefix(max(1, costs.count/2))
        return phase.reduce(0, +)/Float(phase.count)
    }

    private static func dtw(_ a: [BasicFeature], _ b: [BasicFeature]) -> Float {
        var previous = [Float](repeating: .infinity, count: b.count+1)
        previous[0] = 0
        for i in a.indices {
            var current = [Float](repeating: .infinity, count: b.count+1)
            for j in b.indices where abs(i-j) <= 5 {
                current[j+1] = cost(a[i], b[j]) + min(previous[j], previous[j+1], current[j])
            }
            previous = current
        }
        return previous[b.count] / Float(max(a.count, b.count))
    }

    func candidate(_ frames: [SkeletonFrame]) -> BasicCandidate {
        let unavailable = BasicCandidate(scores: BasicSignScore.rows(labels: bank.labels))
        guard let end = frames.last, !end.hands.isEmpty else { return unavailable }
        var byLabel: [String: Float] = [:]
        // Every label sees the SAME movement window. A static candidate must
        // not cherry-pick a short still portion while a dynamic sign is judged
        // against the complete movement.
        for duration in [bank.windowMS ?? 1800] {
            guard let query = Self.sequence(frames.filter { $0.timestampMS >= end.timestampMS-duration },
                                           minimum: bank.queryFrames ?? 4) else { continue }
            let mirror = query.map { $0.mirrored() }
            let motion = Self.trajectorySignature(query), mirroredMotion = Self.trajectorySignature(mirror)
            for (label, reference, referenceMotion) in references {
                let distance = min(Self.dtw(query, reference) + Self.motionDistance(motion, referenceMotion),
                                   Self.dtw(mirror, reference) + Self.motionDistance(mirroredMotion, referenceMotion))
                byLabel[label] = min(byLabel[label] ?? .infinity, distance)
            }
            for label in Array(byLabel.keys) {
                byLabel[label]! += (bank.ruleWeight ?? 0.2) * Self.anatomicalPenalty(label: label, sequence: query)
            }
        }
        let sorted = byLabel.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }
        let scores = BasicSignScore.rows(labels: bank.labels, distances: byLabel)
        guard sorted.count >= 2 else { return BasicCandidate(scores: scores) }
        return BasicCandidate(label: sorted[0].key, distance: sorted[0].value,
                              margin: max(0, (sorted[1].value-sorted[0].value)/max(sorted[1].value, 0.00001)),
                              scores: scores)
    }

    func accepted(_ candidate: BasicCandidate) -> String? {
        bank.maxDistance > 0 && candidate.distance <= bank.maxDistance && candidate.margin >= bank.minMargin
            && bank.labels.contains(candidate.label ?? "") ? candidate.label : nil
    }
}

/// Two consecutive accepted windows, not calibrated confidence percentages.
struct BasicSignStability {
    private var pending: String?
    private var count = 0
    mutating func reset() { pending = nil; count = 0 }
    mutating func update(_ label: String?) -> String? {
        guard let label else { reset(); return nil }
        count = pending == label ? count+1 : 1
        pending = label
        return count >= 2 ? label : nil
    }
}
