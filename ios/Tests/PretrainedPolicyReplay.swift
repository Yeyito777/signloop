import Foundation

/// Desktop verification of the exact input/output contract, without iOS SDKs.
@main
struct PretrainedPolicyReplay {
    struct Query: Decodable {
        let frames: [LandmarkFrame]
        let logits: [Float]?
        let unknown: Bool
        let acceptedLabel: String?
    }
    struct Fixture: Decodable { let queries: [Query] }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: message, code: 1) }
    }
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            throw NSError(domain: "Usage: policy-replay fixture.json vocabulary.json", code: 1)
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from:
            Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let vocabulary = try JSONDecoder().decode([String: Int].self, from:
            Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        let policy = try PretrainedSignPolicy(vocabulary: vocabulary)
        for query in fixture.queries {
            let packed = try PretrainedSignPolicy.pack(query.frames)
            try require((packed == nil) == (query.logits == nil), "Packing quality gate mismatch")
            if let packed {
                try require(packed.count == query.frames.count*543*3, "Invalid tensor length")
                for frame in query.frames.indices {
                    try require(packed[(frame*543*3)..<((frame*543+468)*3)].allSatisfy(\.isNaN),
                                "Face landmarks were invented")
                    try require(packed[((frame*543+489)*3)..<((frame*543+522)*3)].allSatisfy(\.isNaN),
                                "Body landmarks were invented")
                }
            }
            if let logits = query.logits {
                let decision = try policy.decode(logits)
                try require(decision.unknown == query.unknown, "Logit rejection mismatch")
                try require((decision.unknown ? nil : decision.candidates.first?.label) == query.acceptedLabel,
                            "Accepted word mismatch")
            }
        }
        var logits = Array(repeating: Float(0), count: 250)
        let unsupported = vocabulary.first { PretrainedSignPolicy.supported[$0.key] == nil }!.value
        logits[unsupported] = 100
        logits[vocabulary["hello"]!] = 50
        try require(try policy.decode(logits).unknown, "Unsupported winner forced into known vocabulary")
        for bad in [[Float](repeating: 0, count: 249), [Float](repeating: .nan, count: 250)] {
            do {
                _ = try policy.decode(bad)
                throw NSError(domain: "Malformed logits accepted", code: 1)
            } catch PretrainedSignPolicy.Failure.invalidLogits { }
        }
        print("PASS: native tensor gates, absent context and logit policy match \(fixture.queries.count) synthetic cases")
    }
}
