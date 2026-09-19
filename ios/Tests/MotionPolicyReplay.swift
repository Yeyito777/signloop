import Foundation

@main
struct MotionPolicyReplay {
    struct Query: Decodable {
        let frames: [LandmarkFrame]
        let motion: Double
    }
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Expected local fixture") }
        let queries = try JSONDecoder().decode([Query].self, from:
            Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        for query in queries {
            _ = try PretrainedSignPolicy.pack(query.frames) // validate before metric
            let value = PretrainedSignPolicy.pinchMotion(query.frames)
            guard abs(value-query.motion) < 0.00002 else { fatalError("Motion parity mismatch") }
            for label in ["NO", "HELLO", "UNSUPPORTED:cat"] {
                for wasUnknown in [false, true] {
                    let result = Classification(candidates: [.init(label: label, score: 0.9)],
                                                unknown: wasUnknown, reason: "input_policy")
                    let guarded = PretrainedSignPolicy.applyingArticulation(result, frames: query.frames)
                    let rejected = !wasUnknown && label == "NO" && query.motion < 0.075
                    guard guarded.unknown == (wasUnknown || rejected),
                          guarded.reason == (rejected ? "insufficient_articulation" : "input_policy"),
                          guarded.candidates.first?.label == label,
                          guarded.model == PretrainedSignPolicy.motionModelName else {
                        fatalError("Guard changed a label or failed to reject")
                    }
                }
            }
        }
        print("PASS: native articulation and rejection parity for \(queries.count) windows")
    }
}
