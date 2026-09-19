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

    func validate() throws {
        guard version == 1, labels.count == 16, Set(labels).count == 16,
              references.count <= 128, !references.isEmpty,
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
                             "FINISH", "GOOD", "BAD", "NAME", "MY", "SORRY", "STOP", "YOU"]
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
    // Side-specific image-XY blocks. z is deliberately not mixed across models.
    var hands: [[Float]?]
    var body: [[Float]?]
    var face: [Float]?
    var time: Int
    var hasHand: Bool { hands.contains { $0 != nil } }
    var valid: Bool {
        hands.count == 2 && body.count == 2 &&
        hands.allSatisfy { $0.map { $0.count == 42 && $0.allSatisfy { $0.isFinite && abs($0) < 100 } } ?? true } &&
        body.allSatisfy { $0.map { $0.count == 4 && $0.allSatisfy { $0.isFinite && abs($0) < 100 } } ?? true } &&
        (face.map { $0.count == 5 && $0.allSatisfy { $0.isFinite && (0...1).contains($0) } } ?? true)
    }

    func mirrored() -> BasicFeature {
        func flip(_ x: [Float]?) -> [Float]? {
            x.map { values in values.enumerated().map { $0.offset % 2 == 0 ? -$0.element : $0.element } }
        }
        return BasicFeature(hands: [flip(hands[1]), flip(hands[0])],
                            body: [flip(body[1]), flip(body[0])], face: face, time: time)
    }
}

final class BasicSignMatcher {
    let bank: BasicReferenceBank
    private var references: [(String, [BasicFeature])] = []
    private(set) var usableReferenceCount = 0

    init(bank: BasicReferenceBank) throws {
        try bank.validate()
        self.bank = bank
        for reference in bank.references {
            if let sequence = reference.features ?? Self.sequence(reference.frames) {
                references.append((reference.label, sequence))
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
        return BasicReferenceBank(version: bank.version, labels: bank.labels,
                                  maxDistance: bank.maxDistance, minMargin: bank.minMargin,
                                  references: packed)
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
            let wrist = xy(p[0]), middle = xy(p[9])
            let palm = hypot(wrist[0]-middle[0], wrist[1]-middle[1])
            guard palm > 0.008 else { continue }
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
                [(point.x*aspect-wrist[0])/palm, (point.y-wrist[1])/palm]
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
        let result = BasicFeature(hands: hands, body: body, face: face, time: frame.timestampMS)
        return result.valid ? result : nil
    }

    private static func sequence(_ frames: [SkeletonFrame]) -> [BasicFeature]? {
        let features = frames.compactMap(feature)
        guard features.filter(\.hasHand).count >= 6,
              let first = features.firstIndex(where: \.hasHand),
              let last = features.lastIndex(where: \.hasHand),
              features[last].time-features[first].time >= 300 else { return nil }
        let active = Array(features[first...last])
        // Preserve missing observations inside the gesture. Time-based
        // subsampling removes FPS dependence without inventing coordinates.
        let start = active[0].time, duration = active.last!.time-start
        return (0..<16).map { i in
            let time = start + duration*i/15
            return active.min { abs($0.time-time) < abs($1.time-time) }!
        }
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
            value += compare(a.hands[side], b.hands[side], missing: 0.7)
            value += 1.5 * compare(a.body[side], b.body[side], missing: 0.5)
        }
        value += 0.15 * compare(a.face, b.face, missing: 0)
        return value / 5
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
        // Multiple causal windows accommodate short/long signs; never include
        // future frames or use a full-clip label to select a live window.
        for duration in [700, 1400, 2400] {
            guard let query = Self.sequence(frames.filter { $0.timestampMS >= end.timestampMS-duration }) else { continue }
            let mirror = query.map { $0.mirrored() }
            for (label, reference) in references {
                let distance = min(Self.dtw(query, reference), Self.dtw(mirror, reference))
                byLabel[label] = min(byLabel[label] ?? .infinity, distance)
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
