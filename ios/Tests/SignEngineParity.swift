import CoreML
import Foundation

/// Golden-vector parity for the Swift SignEngine port against the Python reference
/// (recognition/*.py). Fixture: ios/Tests/Fixtures/sign_engine_golden.json.
/// Optional Core ML check: SIGN_ENGINE_DIR=<export dir> SIGN_ENGINE_COREML_GOLDEN=<json>.
@main
struct SignEngineParity {
    static var failures = 0
    static var checks = 0

    static func check(_ ok: Bool, _ message: @autoclosure () -> String) {
        checks += 1
        if !ok { failures += 1; print("FAIL:", message()) }
    }

    static func maxDiff(_ a: [Float], _ b: [Double]) -> Double {
        guard a.count == b.count else { return .infinity }
        return zip(a, b).map { abs(Double($0) - $1) }.max() ?? 0
    }

    static func decodeFrames(_ any: Any) throws -> [LandmarkFrame] {
        try JSONDecoder().decode([LandmarkFrame].self, from: JSONSerialization.data(withJSONObject: any))
    }

    static func main() throws {
        let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "ios/Tests/Fixtures/sign_engine_golden.json"
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]

        // ---- feature parity
        for c in root["feature_cases"] as! [[String: Any]] {
            let name = c["name"] as! String
            let cfgData = try JSONSerialization.data(withJSONObject: c["config"] as Any)
            let cfg = try JSONDecoder().decode(SignFeatures.Config.self, from: cfgData)
            let out = try SignFeatures.featurize(frames: decodeFrames(c["frames"]!), cfg)
            let e = c["expected"] as! [String: Any]
            for (key, got) in [("nodes", out.nodes), ("glob", out.glob), ("motion", out.motion), ("mask", out.mask), ("meta", out.meta)] {
                let d = maxDiff(got, e[key] as! [Double])
                check(d < 5e-4, "features[\(name)].\(key) max diff \(d)")
            }
            check(abs(out.quality - (e["quality"] as! Double)) < 1e-4, "features[\(name)].quality \(out.quality)")
        }

        // ---- segmenter parity: identical state after every frame, identical segments
        let seg = root["segmenter"] as! [String: Any]
        let segCfg = try JSONDecoder().decode(SignSegmenter.Config.self, from: JSONSerialization.data(withJSONObject: seg["config"] as Any))
        let frames = try decodeFrames(seg["frames"]!)
        let expectedStates = seg["expected_states"] as! [String]
        let expectedSegments = seg["expected_segments"] as! [[String: Any]]
        var segmenter = SignSegmenter(segCfg)
        var got: [(Int, Int, String, Int)] = []
        var badStates = 0
        for (i, f) in frames.enumerated() {
            if let s = segmenter.update(f) {
                got.append((s.startMS, s.endMS, s.reason, s.frames.count))
                segmenter.finish(f.timestampMS)
            }
            if segmenter.state.rawValue != expectedStates[i] { badStates += 1 }
        }
        check(badStates == 0, "segmenter state mismatches: \(badStates) of \(frames.count)")
        check(got.count == expectedSegments.count, "segment count \(got.count) vs \(expectedSegments.count)")
        for (g, e) in zip(got, expectedSegments) {
            check(g.0 == e["start_ms"] as! Int && g.1 == e["end_ms"] as! Int && g.2 == e["reason"] as! String && g.3 == e["n_frames"] as! Int,
                  "segment \(g) vs \(e)")
        }

        // ---- decision rule parity
        for c in root["decisions"] as! [[String: Any]] {
            let p = c["policy"] as! [String: Any]
            let doc: [String: Any] = [
                "policy": p,
                "feature": try JSONSerialization.jsonObject(with: JSONEncoder().encode(SignFeatures.Config())),
                "segmenter": try JSONSerialization.jsonObject(with: JSONEncoder().encode(SignSegmenter.Config())),
                "labels": (p["known"] as! [String]) + ["UNKNOWN"],
            ]
            let policy = try JSONDecoder().decode(SignPolicy.self, from: JSONSerialization.data(withJSONObject: doc))
            let quality = c["quality"] as! Double
            for (row, exp) in zip(c["logits"] as! [[Double]], c["expected"] as! [[String: Any]]) {
                let (idx, tier) = SignDecision.decide(policy, logits: row, emb: [0, 0, 0, 0], quality: quality)
                let s = SignDecision.score(policy.policy.scorer, logits: row, emb: [], policy: policy)
                check(idx == exp["index"] as! Int && tier == exp["tier"] as! String,
                      "decide[\(policy.policy.scorer)] \(idx),\(tier) vs \(exp)")
                check(abs(s - (exp["score"] as! Double)) < 1e-4, "score[\(policy.policy.scorer)] \(s) vs \(exp["score"]!)")
            }
        }

        // ---- robustness / contract
        check((try? SignFeatures.featurize(frames: [])) == nil, "empty frames must throw")
        check((try? SignFeatures.featurize(frames: [frames[0]])) == nil, "single frame must throw")
        var dup = Array(frames.prefix(10)); dup[5] = dup[4]
        check((try? SignFeatures.featurize(frames: dup)) == nil, "non-increasing timestamps must throw")
        let inf = try JSONDecoder().decode(SignPolicy.Flex.self, from: Data("\"inf\"".utf8))
        check(inf.value == .infinity, "\"inf\" threshold must decode to +infinity")
        var bad = SignFeatures.Config(); bad.rotate = true
        check(bad.unsupported == ["rotate"], "unsupported feature flags are reported")

        // ---- optional: Core ML output compatibility for a locally exported model
        if let dir = ProcessInfo.processInfo.environment["SIGN_ENGINE_DIR"],
           let goldenPath = ProcessInfo.processInfo.environment["SIGN_ENGINE_COREML_GOLDEN"] {
            let engine = try SignEngine.load(directory: URL(fileURLWithPath: dir), units: .cpuOnly)
            let golden = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: goldenPath))) as! [String: Any]
            let runner = try CoreMLSignRunner(compiledModel: try compiled(dir), steps: engine.policy.feature.steps, units: .cpuOnly)
            var times: [Double] = []
            for c in golden["coreml"] as! [[String: Any]] {
                let f = try SignFeatures.featurize(frames: decodeFrames(c["frames"]!), engine.policy.feature)
                let t0 = CFAbsoluteTimeGetCurrent()
                let (logits, _) = try runner.run(f)
                times.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                let want = c["logits"] as! [Double]
                let d = zip(logits, want).map { abs($0 - $1) }.max() ?? .infinity
                check(d < 0.05, "CoreML logits differ from Python by \(d) for \(c["class"]!)")
                let argmax = { (v: [Double]) in v.indices.max { v[$0] < v[$1] }! }
                check(argmax(logits) == argmax(want), "CoreML argmax differs for \(c["class"]!)")
            }
            print(String(format: "coreml single-inference ms (this Mac, includes feature copy): %@", times.map { String(format: "%.2f", $0) }.joined(separator: ", ")))
        } else {
            print("(Core ML section skipped: set SIGN_ENGINE_DIR and SIGN_ENGINE_COREML_GOLDEN)")
        }

        print("\(checks - failures)/\(checks) checks passed")
        if failures > 0 { exit(1) }
    }

    static func compiled(_ dir: String) throws -> URL {
        let compiledURL = URL(fileURLWithPath: dir).appendingPathComponent("SignEngine.mlmodelc")
        if FileManager.default.fileExists(atPath: compiledURL.path) { return compiledURL }
        return try MLModel.compileModel(at: URL(fileURLWithPath: dir).appendingPathComponent("SignEngine.mlpackage"))
    }
}
