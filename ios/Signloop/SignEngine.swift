import CoreML
import CryptoKit
import Foundation

/// What the mobile layer receives. Never raw landmarks; never a label the user has not been able
/// to confirm (confirmation stays in the JS session flow).
struct SignPrediction: Equatable {
    /// Supported label, "UNKNOWN", or nil when no attempt finished on this frame.
    var label: String?
    /// Temperature-scaled probability of the top supported class (0 when unavailable).
    var confidence: Double
    /// idle | possible_sign | sign_in_progress | prediction
    var state: String
    /// 0...1 quality of tracking over the last attempted sign.
    var trackingQuality: Double
    /// show | retry | unknown | low_tracking | unusable (only when label != nil)
    var tier: String?
    var reason: String?
    var segment: ClosedRange<Int>?
}

/// Thresholds and metadata derived on validation signers (recognition/openset.py).
struct SignPolicy: Decodable {
    struct Flex: Decodable {
        let value: Double
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let d = try? c.decode(Double.self) { value = d; return }
            let s = try c.decode(String.self)
            value = s == "inf" ? .infinity : (s == "-inf" ? -.infinity : .nan)
        }
    }
    struct Body: Decodable {
        let scorer: String
        let temperature: Double
        let tauHigh: Flex
        let tauLow: Flex
        let qualityMin: Double
        let known: [String]
        enum CodingKeys: String, CodingKey {
            case scorer, temperature, known
            case tauHigh = "tau_high", tauLow = "tau_low", qualityMin = "quality_min"
        }
    }
    struct Prototypes: Decodable {
        let means: [[Double]]
        let invVar: [Double]
        enum CodingKeys: String, CodingKey { case means, invVar = "inv_var" }
    }
    let policy: Body
    let feature: SignFeatures.Config
    let segmenter: SignSegmenter.Config
    let labels: [String]
    let prototypes: Prototypes?
}

struct SignManifest: Decodable {
    let shippable: Bool
    let steps: Int
    let labels: [String]
    let modelSHA256: String
    enum CodingKeys: String, CodingKey { case shippable, steps, labels, modelSHA256 = "model_sha256" }
}

/// Model output -> decision. Port of recognition/openset.py (scores + decide). Pure and testable.
enum SignDecision {
    static func softmax(_ z: [Double], _ t: Double) -> [Double] {
        let s = z.map { $0 / t }, m = s.max() ?? 0
        let e = s.map { exp($0 - m) }, d = e.reduce(0, +)
        return e.map { $0 / d }
    }
    private static func logSumExp(_ v: [Double]) -> Double {
        guard let m = v.max(), m.isFinite else { return -.infinity }
        return m + log(v.reduce(0) { $0 + exp($1 - m) })
    }

    static func score(_ name: String, logits: [Double], emb: [Double], policy: SignPolicy) -> Double {
        let k = policy.policy.known.count, t = policy.policy.temperature
        let z = logits.map { $0 / t }
        switch name {
        case "log_odds":
            let top = z[0..<k].max()!
            let rest = z.filter { $0 != top }
            return top - logSumExp(rest)
        case "max_prob":
            return softmax(logits, t)[0..<k].max()!
        case "entropy":
            let p = softmax(logits, t)
            return 1 + p.reduce(0) { $0 + $1 * log(min(1, max(1e-12, $1))) } / log(Double(p.count))
        case "margin":
            let p = softmax(logits, t).sorted()
            return p[p.count - 1] - p[p.count - 2]
        case "energy":
            return t * logSumExp(Array(z[0..<k]))
        case "prototype":
            guard let protos = policy.prototypes else { return -.infinity }
            var best = Double.infinity
            for mean in protos.means {
                var d = 0.0
                for i in 0..<emb.count { d += pow(emb[i] - mean[i], 2) * protos.invVar[i] }
                best = min(best, d / Double(emb.count))
            }
            return -best
        default:
            return -.infinity
        }
    }

    /// -> (label index or K for UNKNOWN, tier).
    static func decide(_ policy: SignPolicy, logits: [Double], emb: [Double], quality: Double) -> (Int, String) {
        let k = policy.policy.known.count
        var pred = 0
        for (i, v) in logits.enumerated() where v > logits[pred] { pred = i }
        let s = score(policy.policy.scorer, logits: logits, emb: emb, policy: policy)
        if quality < policy.policy.qualityMin { return (k, "low_tracking") }
        if pred == k || s < policy.policy.tauLow.value || s.isNaN { return (k, "unknown") }
        if s < policy.policy.tauHigh.value { return (pred, "retry") }
        return (pred, "show")
    }
}

protocol SignModelRunner {
    /// -> (logits (K+1), embedding)
    func run(_ features: SignFeatures.Output) throws -> ([Double], [Double])
}

/// Core ML runner for the fixed-shape (batch 1, T steps) package produced by
/// recognition/export_coreml.py. Reuses its input arrays between calls.
final class CoreMLSignRunner: SignModelRunner {
    private let model: MLModel
    private let steps: Int
    private let arrays: [String: MLMultiArray]

    init(compiledModel: URL, steps: Int, units: MLComputeUnits = .all) throws {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = units
        model = try MLModel(contentsOf: compiledModel, configuration: cfg)
        self.steps = steps
        func make(_ shape: [Int]) throws -> MLMultiArray { try MLMultiArray(shape: shape.map(NSNumber.init), dataType: .float32) }
        arrays = [
            "nodes": try make([1, steps, 2, 21, SignFeatures.nodeChannels]),
            "glob": try make([1, steps, 2, SignFeatures.globalWidth]),
            "motion": try make([1, steps, SignFeatures.motionCount]),
            "mask": try make([1, steps, 3]),
            "meta": try make([1, SignFeatures.metaCount]),
        ]
    }

    private func fill(_ name: String, _ values: [Float]) {
        let array = arrays[name]!
        precondition(array.count == values.count, "\(name): expected \(array.count) values, got \(values.count)")
        values.withUnsafeBufferPointer { src in
            array.dataPointer.bindMemory(to: Float.self, capacity: values.count).update(from: src.baseAddress!, count: values.count)
        }
    }

    func run(_ f: SignFeatures.Output) throws -> ([Double], [Double]) {
        guard f.steps == steps else { throw SignEngine.Failure.invalidModelOutput }
        fill("nodes", f.nodes); fill("glob", f.glob); fill("motion", f.motion); fill("mask", f.mask); fill("meta", f.meta)
        let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: arrays))
        func read(_ key: String) throws -> [Double] {
            guard let a = out.featureValue(for: key)?.multiArrayValue else { throw SignEngine.Failure.invalidModelOutput }
            return (0..<a.count).map { a[$0].doubleValue }
        }
        let logits = try read("logits"), emb = try read("emb")
        guard logits.allSatisfy(\.isFinite), emb.allSatisfy(\.isFinite) else { throw SignEngine.Failure.invalidModelOutput }
        return (logits, emb)
    }
}

/// Frame in, Prediction out. All state lives on one serial queue; the camera queue is never blocked.
/// No network access, no persistence of landmarks.
final class SignEngine {
    enum Failure: Error { case notShippable, unsupportedFeatures([String]), mismatch, invalidModelOutput, badPackage }

    let policy: SignPolicy
    private let runner: SignModelRunner
    private let queue = DispatchQueue(label: "com.signloop.sign-engine", qos: .userInitiated)
    private var segmenter: SignSegmenter
    private var lastQuality = 0.0
    private var lastState = ""
    /// Called on the engine queue, when a prediction completes or the state changes. Hop to main yourself.
    var onPrediction: ((SignPrediction) -> Void)?

    init(policy: SignPolicy, runner: SignModelRunner) throws {
        guard policy.feature.unsupported.isEmpty else { throw Failure.unsupportedFeatures(policy.feature.unsupported) }
        guard policy.labels.count == policy.policy.known.count + 1, policy.labels.last == "UNKNOWN" else { throw Failure.mismatch }
        self.policy = policy
        self.runner = runner
        segmenter = SignSegmenter(policy.segmenter)
    }

    /// A bundle either carries the package in a `SignEngine` folder (standalone app) or flattened at
    /// its resource root (CocoaPods resource bundle). Returns nil when no model is bundled.
    static func locate(in bundle: Bundle) -> URL? {
        if let folder = bundle.url(forResource: "SignEngine", withExtension: nil),
           FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) { return folder }
        if let flat = bundle.url(forResource: "manifest", withExtension: "json"),
           FileManager.default.fileExists(atPath: flat.deletingLastPathComponent().appendingPathComponent("policy.json").path) {
            return flat.deletingLastPathComponent()
        }
        return nil
    }

    /// Loads policy.json + manifest.json + SignEngine.mlmodelc (or .mlpackage, compiled on first use)
    /// from `directory`. Refuses a model whose training data is not documented as redistributable.
    static func load(directory: URL, units: MLComputeUnits = .all) throws -> SignEngine {
        let manifest = try JSONDecoder().decode(SignManifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        guard manifest.shippable else { throw Failure.notShippable }
        let policy = try JSONDecoder().decode(SignPolicy.self, from: Data(contentsOf: directory.appendingPathComponent("policy.json")))
        guard policy.feature.steps == manifest.steps, policy.labels == manifest.labels else { throw Failure.mismatch }
        let compiled = directory.appendingPathComponent("SignEngine.mlmodelc")
        let package = directory.appendingPathComponent("SignEngine.mlpackage")
        var model = compiled
        if !FileManager.default.fileExists(atPath: compiled.path) {
            guard FileManager.default.fileExists(atPath: package.path), try sha256(directory: package) == manifest.modelSHA256 else {
                throw Failure.badPackage
            }
            model = try MLModel.compileModel(at: package)
        }
        return try SignEngine(policy: policy, runner: CoreMLSignRunner(compiledModel: model, steps: manifest.steps, units: units))
    }

    /// Same hashing as recognition/export_coreml.py:sha256_dir.
    static func sha256(directory: URL) throws -> String {
        var hasher = SHA256()
        let base = directory.standardizedFileURL.path
        var files: [String] = []
        if let e = FileManager.default.enumerator(atPath: base) {
            for case let name as String in e {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: base + "/" + name, isDirectory: &isDir)
                if !isDir.boolValue { files.append(name) }
            }
        }
        for name in files.sorted() {
            hasher.update(data: Data(name.utf8))
            hasher.update(data: try Data(contentsOf: URL(fileURLWithPath: base + "/" + name)))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func reset() { queue.async { self.segmenter.reset(); self.lastQuality = 0; self.lastState = "" } }

    /// Call from the camera queue for every tracked frame (including frames with no hand).
    func receive(_ frame: LandmarkFrame) {
        queue.async { [self] in
            guard let segment = segmenter.update(frame) else {
                let now = segmenter.state.rawValue
                if now != lastState {
                    lastState = now
                    onPrediction?(SignPrediction(label: nil, confidence: 0, state: now, trackingQuality: lastQuality,
                                                 tier: nil, reason: nil, segment: nil))
                }
                return
            }
            var prediction = classify(segment.frames)
            prediction.segment = segment.startMS...segment.endMS
            prediction.reason = prediction.reason ?? segment.reason
            lastQuality = prediction.trackingQuality
            segmenter.finish(frame.timestampMS)
            lastState = segmenter.state.rawValue
            onPrediction?(prediction)
        }
    }

    /// Synchronous classification of one already-segmented attempt (also used by tests/replay).
    func classify(_ frames: [LandmarkFrame]) -> SignPrediction {
        let state = SignSegmenter.State.prediction.rawValue
        let features: SignFeatures.Output
        do { features = try SignFeatures.featurize(frames: frames, policy.feature) }
        catch { return SignPrediction(label: "UNKNOWN", confidence: 0, state: state, trackingQuality: 0, tier: "unusable", reason: "\(error)") }
        guard let (logits, emb) = try? runner.run(features) else {
            return SignPrediction(label: "UNKNOWN", confidence: 0, state: state, trackingQuality: features.quality, tier: "unusable", reason: "model_failure")
        }
        let k = policy.policy.known.count
        let (index, tier) = SignDecision.decide(policy, logits: logits, emb: emb, quality: features.quality)
        let probs = SignDecision.softmax(logits, policy.policy.temperature)
        let label = index < k && tier == "show" ? policy.policy.known[index] : "UNKNOWN"
        return SignPrediction(label: label, confidence: probs[0..<k].max() ?? 0, state: state,
                              trackingQuality: features.quality, tier: tier, reason: nil, segment: nil)
    }
}
