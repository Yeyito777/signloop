import Foundation

/// Pure input/output contract for the research-only 250-word candidate.
/// Face/pose slots remain missing, never fabricated. Scores are not probabilities
/// of correct ASL recognition. The camera UI does not select this policy yet.
struct PretrainedSignPolicy {
    static let modelName = "kaggle-islr-250-hands-research-v1"
    static let supported = ["hello": "HELLO", "yes": "YES", "no": "NO",
                            "please": "PLEASE", "thankyou": "THANK_YOU"]
    enum Failure: Error { case invalidFrames, invalidVocabulary, invalidLogits }
    private let labels: [String]
    let minScore = 0.4
    let minMargin = 0.05

    init(vocabulary: [String: Int]) throws {
        guard vocabulary.count == 250, Set(vocabulary.values) == Set(0..<250),
              Set(Self.supported.keys).isSubset(of: Set(vocabulary.keys)) else {
            throw Failure.invalidVocabulary
        }
        var labels = Array(repeating: "", count: 250)
        for (name, index) in vocabulary { labels[index] = Self.supported[name] ?? "UNSUPPORTED:" + name }
        self.labels = labels
    }

    func decode(_ logits: [Float]) throws -> Classification {
        guard logits.count == 250, logits.allSatisfy(\.isFinite) else { throw Failure.invalidLogits }
        let maximum = Double(logits.max()!)
        let exps = logits.map { exp(Double($0)-maximum) }
        let denominator = exps.reduce(0, +)
        let order = logits.indices.sorted {
            logits[$0] == logits[$1] ? $0 < $1 : logits[$0] > logits[$1]
        }
        let first = order[0], second = order[1]
        let score = exps[first]/denominator, runner = exps[second]/denominator
        let supported = Self.supported.values.contains(labels[first])
        let accepted = supported && score > minScore && score-runner >= minMargin
        return Classification(candidates: [first, second].map {
            Classification.Candidate(label: labels[$0], score: Float(exps[$0]/denominator))
        }, unknown: !accepted, reason: accepted ? "learned_match" :
            (supported ? "uncertain" : "unsupported_label"), model: Self.modelName)
    }

    static func pack(_ frames: [LandmarkFrame]) throws -> [Float]? {
        guard frames.count <= 90 else { throw Failure.invalidFrames }
        var last = -1
        for frame in frames {
            let aspect = frame.imageAspectRatio ?? 1
            guard frame.timestampMS > last, frame.timestampMS < 1_000_000_000_000_000,
                  frame.hands.count <= 2, aspect.isFinite, (0.1...10).contains(aspect) else {
                throw Failure.invalidFrames
            }
            last = frame.timestampMS
            for hand in frame.hands {
                guard ["Left", "Right", "Hand"].contains(hand.handedness), hand.joints.count == 21,
                      hand.joints.allSatisfy({ p in
                          [p.x, p.y, p.z].allSatisfy { $0.isFinite && abs($0) <= 10 }
                      }) else { throw Failure.invalidFrames }
            }
        }
        if let first = frames.first, let end = frames.last, end.timestampMS-first.timestampMS > 3000 {
            throw Failure.invalidFrames
        }
        guard frames.count >= 6, frames.last?.hands.isEmpty == false,
              frames.filter({ !$0.hands.isEmpty }).count*2 >= frames.count else { return nil }
        var tensor = Array(repeating: Float.nan, count: frames.count*543*3)
        var observed = false
        for (i, frame) in frames.enumerated() {
            let mirrored = frame.mirrored ?? true
            var chosen: [String: TrackedHand] = [:]
            func better(_ a: TrackedHand, _ b: TrackedHand) -> Bool {
                func confidence(_ h: TrackedHand) -> Float {
                    h.handednessScore.isFinite ? min(1, max(0, h.handednessScore)) : 0.5
                }
                if confidence(a) != confidence(b) { return confidence(a) > confidence(b) }
                for (x, y) in zip(a.joints, b.joints) {
                    for (u, v) in [(x.x, y.x), (x.y, y.y), (x.z, y.z)] where u != v { return u < v }
                }
                return false
            }
            for hand in frame.hands {
                var side = hand.handedness
                if !mirrored { side = side == "Left" ? "Right" : (side == "Right" ? "Left" : side) }
                guard side == "Left" || side == "Right" else { continue }
                if chosen[side] == nil || better(hand, chosen[side]!) { chosen[side] = hand }
            }
            for (side, hand) in chosen {
                observed = true
                let start = side == "Left" ? 468 : 522
                for (j, p) in hand.joints.enumerated() {
                    let offset = (i*543+start+j)*3
                    tensor[offset] = mirrored ? p.x : 1-p.x
                    tensor[offset+1] = p.y
                    tensor[offset+2] = p.z
                }
            }
        }
        return observed ? tensor : nil
    }
}
