import Foundation

enum TaughtExpressionLabel: String, CaseIterable, Codable, Identifiable {
    case neutral, joy, anger, fear, sadness, disgust
    var id: String { rawValue }
    var title: String { self == .neutral ? "Relaxed face" : rawValue.capitalized }
    var instruction: String {
        switch self {
        case .neutral: return "Relax your face, with your eyes naturally open."
        case .joy: return "Show the smile you will use in the demo."
        case .anger: return "Show your angry expression, including your natural brow furrow."
        case .fear: return "Show your fear expression, opening your eyes comfortably wider."
        case .sadness: return "Show your sad expression as you will use it in the demo."
        case .disgust: return "Show your “ew” expression. Use the same expression each time; it should look different from your smile."
        }
    }
}

struct ExpressionTeachingError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Five measurements, always in ExpressionCue.allCases order. A taught label
/// describes the ENTIRE vector; there are no hard-coded emotion/cue rules here.
struct ExpressionExample: Codable, Equatable {
    var center: [Double]
    var spread: [Double]
    var sampleCount: Int
    var isValid: Bool {
        center.count == 5 && spread.count == 5 && (12...120).contains(sampleCount) &&
        zip(ExpressionCue.allCases, center).allSatisfy { $1.isFinite && $0.rawBounds.contains($1) } &&
        spread.allSatisfy { $0.isFinite && (0...4).contains($0) }
    }
    static func summarize(_ observations: [ExpressionObservation]) -> Self {
        let columns = ExpressionCue.allCases.map { cue in observations.map { $0.values[cue]! }.sorted() }
        func percentile(_ column: [Double], _ p: Double) -> Double { column[Int(Double(column.count-1)*p)] }
        return Self(center: columns.map { percentile($0, 0.5) },
                    spread: columns.map { (percentile($0, 0.9)-percentile($0, 0.1))/2 },
                    sampleCount: observations.count)
    }
}

struct ExpressionValidation: Codable, Equatable {
    var example: ExpressionExample
    var accepted: Int
    var total: Int
    var longestHoldMS: Int
    var isValid: Bool {
        example.isValid && (300...2000).contains(longestHoldMS) && total == example.sampleCount && accepted >= 0 && accepted <= total &&
        Double(accepted)/Double(total) >= 0.8
    }
}

struct TaughtExpressionProfile: Codable, Equatable {
    // Independent schema: old threshold calibration can never masquerade as taught examples.
    var schemaVersion = 1
    var measurementVersion = "face-geometry-mouth-v1"
    var id: String
    var createdAt: Date
    var camera: String
    var pose: ExpressionPose
    var examples: [TaughtExpressionLabel: [ExpressionExample]]
    var validation: [TaughtExpressionLabel: ExpressionValidation]

    func validatedModel() throws -> TaughtExpressionModel {
        guard schemaVersion == 1, measurementVersion == "face-geometry-mouth-v1",
              UUID(uuidString: id) != nil, createdAt.timeIntervalSince1970.isFinite,
              ["front", "back"].contains(camera), pose.isValid,
              validation.count == TaughtExpressionLabel.allCases.count else {
            throw ExpressionTeachingError(message: "This is not a complete, supported demo expression profile.")
        }
        let model = try TaughtExpressionModel(examples: examples)
        for label in TaughtExpressionLabel.allCases {
            guard let check = validation[label], check.isValid,
                  model.match(check.example.center).label == label else {
                throw ExpressionTeachingError(message: "The saved \(label.title.lowercased()) check is missing or does not match its examples.")
            }
        }
        return model
    }
}

/// Deterministic nearest-example matching with learned scales and rejection.
/// Parameters are computed once when installing a frozen profile, never adapted live.
struct TaughtExpressionModel {
    struct Match {
        var label: TaughtExpressionLabel?
        var alternatives: [TaughtExpressionLabel] = []
        var distance: Double?
    }
    private var examples: [TaughtExpressionLabel: [ExpressionExample]]
    private var scales: [Double]
    private var radii: [TaughtExpressionLabel: Double]

    init(examples: [TaughtExpressionLabel: [ExpressionExample]]) throws {
        guard examples.count == 6, TaughtExpressionLabel.allCases.allSatisfy({
            examples[$0]?.count == 2 && examples[$0]!.allSatisfy(\.isValid)
        }) else { throw ExpressionTeachingError(message: "Capture two examples of your relaxed face and every expression.") }
        let all = TaughtExpressionLabel.allCases.flatMap { examples[$0]! }
        let scales = (0..<5).map { index in
            max(ExpressionCue.allCases[index].noiseFloor * 4,
                all.map { $0.center[index] }.max()! - all.map { $0.center[index] }.min()!,
                all.map { $0.spread[index] * 4 }.max()!)
        }
        func distance(_ a: [Double], _ b: [Double]) -> Double {
            sqrt(zip(zip(a,b),scales).reduce(0) { $0 + pow(($1.0.0-$1.0.1)/$1.1,2) })
        }
        var radii: [TaughtExpressionLabel: Double] = [:]
        for label in TaughtExpressionLabel.allCases {
            let own = examples[label]!
            let other = TaughtExpressionLabel.allCases.filter { $0 != label }
            let closest = other.map { candidate in
                (candidate, own.flatMap { a in examples[candidate]!.map { distance(a.center,$0.center) } }.min()!)
            }.min { $0.1 < $1.1 }!
            guard closest.1 >= 0.18 else {
                throw ExpressionTeachingError(message: "\(label.title) and \(closest.0.title.lowercased()) look too similar in the measured signals. Retake one with a clearer, repeatable difference.")
            }
            let repeatDistance = distance(own[0].center,own[1].center)
            guard repeatDistance < closest.1 * 0.75 else {
                throw ExpressionTeachingError(message: "The two \(label.title.lowercased()) examples differ too much. Retake them using the same comfortable expression.")
            }
            let jitter = own.map { distance($0.spread, Array(repeating: 0, count: 5)) }.max()!
            let radius = min(0.45, closest.1 * 0.42)
            guard jitter * 2 < radius else {
                throw ExpressionTeachingError(message: "\(label.title) moved too much during capture. Retake it while holding your expression and head steady.")
            }
            radii[label] = radius
        }
        self.examples = examples; self.scales = scales; self.radii = radii
    }

    func match(_ vector: [Double]) -> Match {
        guard vector.count == 5, vector.allSatisfy(\.isFinite) else { return Match() }
        let ranked = TaughtExpressionLabel.allCases.map { label in
            (label, examples[label]!.map { example in
                sqrt(zip(zip(vector,example.center),scales).reduce(0) { $0 + pow(($1.0.0-$1.0.1)/$1.1,2) })
            }.min()!)
        }.sorted { $0.1 < $1.1 }
        let first = ranked[0], second = ranked[1]
        guard first.1 <= radii[first.0]! else { return Match(distance: first.1) }
        guard second.1-first.1 >= min(0.10, radii[first.0]! * 0.35) else {
            return Match(alternatives: [first.0,second.0], distance: first.1)
        }
        return Match(label: first.0, distance: first.1)
    }
}

/// File-backed, atomic persistence. Only an explicit install writes a profile.
/// Demo builds use only their bundled profile; training builds prefer an explicit local install.
struct TaughtExpressionStore {
    let localURL: URL
    let bundledURL: URL?
    var allowLocal: Bool = true
    static var standard: Self {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Self(localURL: support.appendingPathComponent("Signloop/demo-expressions.json"),
                    bundledURL: Bundle.main.url(forResource: "DemoExpressionProfile", withExtension: "json"),
                    allowLocal: trainingEnabled)
    }
    static var trainingEnabled: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "ExpressionTrainingEnabled") as? String ?? "YES") == "YES"
    }
    static func decode(_ data: Data) throws -> TaughtExpressionProfile {
        guard data.count <= 262_144 else { throw ExpressionTeachingError(message: "Profile file is too large.") }
        let profile = try JSONDecoder().decode(TaughtExpressionProfile.self, from: data)
        _ = try profile.validatedModel()
        return profile
    }
    static func read(_ url: URL) throws -> TaughtExpressionProfile {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 262_144 else { throw ExpressionTeachingError(message: "Profile file is too large.") }
        return try decode(Data(contentsOf: url))
    }
    static func encode(_ profile: TaughtExpressionProfile) throws -> Data {
        _ = try profile.validatedModel()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(profile)
    }
    func load() -> TaughtExpressionProfile? {
        if allowLocal, let profile = try? Self.read(localURL) { return profile }
        return bundledURL.flatMap { try? Self.read($0) }
    }
    func save(_ profile: TaughtExpressionProfile) throws {
        guard allowLocal else { throw ExpressionTeachingError(message: "This demo build uses its bundled expression profile.") }
        let data = try Self.encode(profile)
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: localURL, options: .atomic)
    }
}

struct TaughtExpressionRuntime {
    enum Result: Equatable {
        case noFace, noProfile, unavailable, wrongCamera, faceForward, unknown, ambiguous
        case holding(TaughtExpressionLabel), active(TaughtExpressionLabel), neutral
        var title: String {
            switch self {
            case .noFace: return "No face"
            case .noProfile: return "No demo profile"
            case .unavailable: return "Signal unavailable"
            case .wrongCamera: return "Use the trained camera"
            case .faceForward: return "Face the camera"
            case .unknown: return "No matching expression"
            case .ambiguous: return "Between expressions"
            case .neutral: return "Relaxed face"
            case .holding(let label): return "Hold \(label.title.lowercased())…"
            case .active(let label): return "\(label.title) preset"
            }
        }
    }
    private(set) var profile: TaughtExpressionProfile?
    private var model: TaughtExpressionModel?
    private(set) var result: Result = .noFace
    private(set) var observation: ExpressionObservation?
    private(set) var distance: Double?
    private var lastMS: Int?
    private var pending: TaughtExpressionLabel?
    private var sinceMS: Int?
    init(profile: TaughtExpressionProfile? = nil) {
        if let profile, let model = try? profile.validatedModel() { self.profile = profile; self.model = model }
    }
    mutating func install(_ profile: TaughtExpressionProfile, store: TaughtExpressionStore = .standard) throws {
        let model = try profile.validatedModel()
        try store.save(profile) // A failed write must not replace the active, previously saved profile.
        self.profile = profile; self.model = model; resetTracking()
    }
    mutating func resetTracking() {
        observation = nil; lastMS = nil; pending = nil; sinceMS = nil; distance = nil; result = .noFace
    }
    mutating func observe(timestampMS: Int, hasFace: Bool, observation: ExpressionObservation?) {
        guard hasFace, timestampMS >= 0 else { resetTracking(); return }
        if let lastMS, timestampMS == lastMS { return }
        if let lastMS, timestampMS < lastMS { resetTracking(); result = .unavailable; return }
        if let lastMS, Double(timestampMS)-Double(lastMS) > 400 { resetTracking() }
        lastMS = timestampMS
        guard let observation, observation.isValid else { resetTracking(); result = .unavailable; return }
        self.observation = observation
        guard let profile, let model else { clear(.noProfile); return }
        guard profile.camera == observation.camera else { clear(.wrongCamera); return }
        guard observation.pose.isNear(profile.pose) else { clear(.faceForward); return }
        let match = model.match(ExpressionCue.allCases.map { observation.values[$0]! })
        distance = match.distance
        guard let label = match.label else { clear(match.alternatives.isEmpty ? .unknown : .ambiguous); return }
        if label == .neutral { clear(.neutral); return }
        if pending != label { pending = label; sinceMS = timestampMS }
        result = Double(timestampMS)-Double(sinceMS ?? timestampMS) >= 300 ? .active(label) : .holding(label)
    }
    private mutating func clear(_ state: Result) { pending = nil; sinceMS = nil; result = state }
}
