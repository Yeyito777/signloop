import Foundation

enum TaughtExpressionLabel: String, CaseIterable, Codable, Identifiable {
    case neutral, joy, anger, fear, sadness, disgust
    var id: String { rawValue }
    var title: String { self == .neutral ? "Relaxed face" : rawValue.capitalized }
    var instruction: String {
        switch self {
        case .neutral: return "Relax your face and jaw, with your mouth in its natural resting position."
        case .joy: return "Show the smile you will use in the demo."
        case .anger: return "Show your angry expression, including your natural brow furrow."
        case .fear: return "Drop your jaw and open your mouth comfortably. Keep the corners relaxed without smiling. Your eyes can stay relaxed."
        case .sadness: return "Show your sad expression as you will use it in the demo."
        case .disgust: return "Scrunch your nose as if something smells bad. Keep your head steady and your mouth relaxed; hold the same comfortable scrunch each time."
        }
    }
}

struct ExpressionTeachingError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Five measurements in ExpressionCue.allCases order, plus the independent raw
/// jaw reference for v3 profiles. Labels describe the whole taught pattern.
struct ExpressionExample: Codable, Equatable {
    var center: [Double]
    var spread: [Double]
    var sampleCount: Int
    var jawOpening: Double?
    var jawSpread: Double?
    var isValid: Bool {
        center.count == 5 && spread.count == 5 && (12...120).contains(sampleCount) &&
        ((jawOpening == nil && jawSpread == nil) ||
            (jawOpening.map { $0.isFinite && (0...1).contains($0) } == true &&
             jawSpread.map { $0.isFinite && (0...1).contains($0) } == true)) &&
        // Accept either representation here; the model checks exact versioned bounds.
        zip(ExpressionCue.allCases, center).allSatisfy { $1.isFinite && ($0 == .disgust ? -2...1 : $0.rawBounds).contains($1) } &&
        spread.allSatisfy { $0.isFinite && (0...4).contains($0) }
    }
    static func summarize(_ observations: [ExpressionObservation]) -> Self {
        let columns = ExpressionCue.allCases.map { cue in observations.map { $0.values[cue]! }.sorted() }
        let jaws = observations.compactMap(\.jawOpening).sorted()
        func percentile(_ column: [Double], _ p: Double) -> Double { column[Int(Double(column.count-1)*p)] }
        return Self(center: columns.map { percentile($0, 0.5) },
                    spread: columns.map { (percentile($0, 0.9)-percentile($0, 0.1))/2 },
                    sampleCount: observations.count,
                    jawOpening: jaws.count == observations.count ? percentile(jaws,0.5) : nil,
                    jawSpread: jaws.count == observations.count ? (percentile(jaws,0.9)-percentile(jaws,0.1))/2 : nil)
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
    var measurementVersion = ExpressionMeasurement.current.rawValue
    var measurement: ExpressionMeasurement? { ExpressionMeasurement(rawValue: measurementVersion) }
    // Absent in build-12 exports. Keep those usable if their wider/noisier
    // captures cannot pass the more sensitive geometry metric.
    var matchingVersion: Int? = 2
    var id: String
    var createdAt: Date
    var camera: String
    var pose: ExpressionPose
    var examples: [TaughtExpressionLabel: [ExpressionExample]]
    var validation: [TaughtExpressionLabel: ExpressionValidation]

    func validatedModel() throws -> TaughtExpressionModel {
        guard schemaVersion == 1, let measurement,
              matchingVersion == nil || matchingVersion == 2,
              measurement == .upperLip || matchingVersion == 2,
              UUID(uuidString: id) != nil, createdAt.timeIntervalSince1970.isFinite,
              ["front", "back"].contains(camera), pose.isValid,
              validation.count == TaughtExpressionLabel.allCases.count else {
            throw ExpressionTeachingError(message: "This is not a complete, supported demo expression profile.")
        }
        do {
            return try checkedModel(sensitiveGeometry: true)
        } catch {
            guard measurement == .upperLip, matchingVersion == nil else { throw error }
            return try checkedModel(sensitiveGeometry: false)
        }
    }

    private func checkedModel(sensitiveGeometry: Bool) throws -> TaughtExpressionModel {
        let model = try TaughtExpressionModel(examples: examples, sensitiveGeometry: sensitiveGeometry, measurement: measurement!)
        for label in TaughtExpressionLabel.allCases {
            guard let check = validation[label], check.isValid,
                  model.match(check.example.center, jawOpening: check.example.jawOpening).label == label else {
                throw ExpressionTeachingError(message: "The saved \(label.title.lowercased()) check is missing or does not match its examples.")
            }
        }
        return model
    }
}

/// Deterministic matching with learned scales and rejection.
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
    private var neutral: [Double]
    private var neutralNoise: [Double]
    let sensitiveGeometry: Bool
    let measurement: ExpressionMeasurement
    private var smileGate: Double?
    private var jawMinimum: Double?
    private var neutralJaw: Double?
    private var jawSignalMinimum: Double?

    init(examples: [TaughtExpressionLabel: [ExpressionExample]], sensitiveGeometry: Bool = true,
         measurement: ExpressionMeasurement = .current) throws {
        guard examples.count == 6, TaughtExpressionLabel.allCases.allSatisfy({
            examples[$0]?.count == 2 && examples[$0]!.allSatisfy { example in
                example.isValid && (!measurement.usesJaw || example.jawOpening != nil) &&
                zip(ExpressionCue.allCases, example.center).allSatisfy { measurement.bounds(for: $0).contains($1) }
            }
        }) else { throw ExpressionTeachingError(message: "Capture two examples of your relaxed face and every expression.") }
        let all = TaughtExpressionLabel.allCases.flatMap { examples[$0]! }
        let centers = TaughtExpressionLabel.allCases.map { label in
            (0..<5).map { index in examples[label]!.map { $0.center[index] }.reduce(0,+) / 2 }
        }
        let neutral = centers[0]
        // Geometry ratios can carry a real, repeatable change of just 0.01.
        // Use captured noise and the smallest distinguishable class difference,
        // so a large sad-brow raise cannot drown out a small angry-brow drop.
        let floors = [0.015, 0.001, measurement.usesJaw ? 0.003 : 0.0005, 0.008, measurement.usesNose ? 0.0015 : 0.015]
        let neutralNoise = (0..<5).map { index in
            max(floors[index] * 3,
                examples[.neutral]!.map { $0.spread[index] * 3 + abs($0.center[index]-neutral[index]) }.max()!)
        }
        if measurement.usesNose {
            let minimumChange = max(neutralNoise[4], examples[.disgust]!.map { $0.spread[4]*3 }.max()!)
            guard examples[.disgust]!.allSatisfy({ $0.center[4]-neutral[4] > minimumChange }) else {
                throw ExpressionTeachingError(message: "The nose scrunch did not show enough repeatable nose movement. Retake disgust with your head steady and scrunch your nose; lifting your lip alone won't pass this check.")
            }
        }
        var smileGate: Double?, jawMinimum: Double?, neutralJaw: Double?, jawSignalMinimum: Double?
        if measurement.usesJaw {
            let restingJaw = examples[.neutral]!.map { $0.jawOpening! }.reduce(0,+)/2
            let jawNoise = examples[.neutral]!.map { $0.jawSpread!*3 + abs($0.jawOpening!-restingJaw) }.max()!
            guard examples[.fear]!.allSatisfy({ $0.jawOpening!-$0.jawSpread!*3-restingJaw > max(0.08,jawNoise) }) else {
                throw ExpressionTeachingError(message: "The jaw signal did not change enough from your relaxed face. Retake fear by lowering your jaw, not just parting your lips.")
            }
            neutralJaw = restingJaw; jawSignalMinimum = max(0.06,jawNoise)
            let smileChange = examples[.joy]!.map { $0.center[0]-$0.spread[0]*3-neutral[0] }.min()!
            guard smileChange > neutralNoise[0]*2 else {
                throw ExpressionTeachingError(message: "The smile needs a clearer, repeatable difference from your relaxed mouth so it can block fear. Retake joy with your usual smile.")
            }
            let gate = neutral[0] + max(neutralNoise[0], smileChange*0.20)
            guard examples[.fear]!.allSatisfy({ $0.center[0]+$0.spread[0]*3 < gate }) else {
                throw ExpressionTeachingError(message: "Your fear examples include a smile. Retake fear by dropping your jaw with the mouth corners relaxed; a smile always blocks fear.")
            }
            let minimum = max(0.03, neutralNoise[2])
            guard examples[.fear]!.allSatisfy({ $0.center[2]-$0.spread[2]*3-neutral[2] > max(0.04, minimum) }) else {
                throw ExpressionTeachingError(message: "The fear examples need a visible jaw drop beyond your relaxed mouth. Retake fear by lowering your jaw, without smiling or just parting your lips.")
            }
            smileGate = gate; jawMinimum = minimum
        }
        let scales = (0..<5).map { index in
            if !sensitiveGeometry {
                return max(ExpressionCue.allCases[index].noiseFloor * 4,
                    all.map { $0.center[index] }.max()! - all.map { $0.center[index] }.min()!,
                    all.map { $0.spread[index] * 4 }.max()!)
            }
            let noise = max(floors[index] * 4, all.map { $0.spread[index] * 4 }.max()!)
            guard index == 1 || index == 2 || (index == 4 && measurement.usesNose) else {
                return max(noise, all.map { $0.center[index] }.max()! - all.map { $0.center[index] }.min()!)
            }
            let differences = centers.flatMap { a in centers.map { b in abs(a[index]-b[index]) } }
            return max(noise, differences.filter { $0 >= noise }.min() ?? noise)
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
        self.neutral = neutral; self.neutralNoise = neutralNoise
        self.sensitiveGeometry = sensitiveGeometry
        self.measurement = measurement
        self.smileGate = smileGate; self.jawMinimum = jawMinimum
        self.neutralJaw = neutralJaw; self.jawSignalMinimum = jawSignalMinimum
    }

    func match(_ vector: [Double], jawOpening: Double? = nil) -> Match {
        guard vector.count == 5, zip(ExpressionCue.allCases,vector).allSatisfy({
            $1.isFinite && measurement.bounds(for: $0).contains($1)
        }) else { return Match() }
        if measurement.usesJaw, jawOpening.map({ $0.isFinite && (0...1).contains($0) }) != true { return Match() }
        if sensitiveGeometry && zip(zip(vector, neutral), neutralNoise).allSatisfy({ abs($0.0.0-$0.0.1) <= $0.1 }) {
            return Match(label: .neutral, distance: 0)
        }
        let ranked: [(TaughtExpressionLabel, Double, Double)] = TaughtExpressionLabel.allCases.map { label -> (TaughtExpressionLabel, Double, Double) in
            if measurement.usesNose, label == .disgust, vector[4]-neutral[4] <= neutralNoise[4] {
                return (label, Double.infinity, radii[label]!)
            }
            if let smileGate, let jawMinimum, label == .fear,
               vector[0] >= smileGate || vector[2]-neutral[2] <= jawMinimum {
                return (label, Double.infinity, radii[label]!)
            }
            if let neutralJaw, let jawSignalMinimum, let jawOpening, label == .fear,
               jawOpening-neutralJaw <= jawSignalMinimum {
                return (label, Double.infinity, radii[label]!)
            }
            let closest = examples[label]!.map { example -> (Double, Double) in
                // A detected smile stays eligible for joy whether the jaw is
                // closed or open. Fear has already been excluded above.
                let ignoreJaw = label == .joy && (smileGate.map { vector[0] >= $0 } ?? false)
                var squaredDistance = 0.0
                for index in 0..<5 where !(ignoreJaw && index == 2) {
                    squaredDistance += pow((vector[index]-example.center[index])/scales[index],2)
                }
                let exact = sqrt(squaredDistance)
                let radius = radii[label]!
                guard sensitiveGeometry, label == .anger || label == .fear else { return (exact, radius) }
                // Accept a softer or slightly stronger version of the SAME
                // learned pattern, not arbitrary movement near a wide radius.
                let direction = (0..<5).map { (example.center[$0]-neutral[$0])/scales[$0] }
                let offset = (0..<5).map { (vector[$0]-neutral[$0])/scales[$0] }
                let lengthSquared = direction.reduce(0) { $0+$1*$1 }
                guard lengthSquared > 0 else { return (exact, radius) }
                let strength = zip(direction, offset).reduce(0) { $0+$1.0*$1.1 } / lengthSquared
                guard (0.30...1.5).contains(strength) else { return (exact, radius) }
                let residual = sqrt(zip(direction, offset).reduce(0) { $0+pow($1.1-strength*$1.0,2) })
                let limit = min(radius, sqrt(lengthSquared)*strength*0.35)
                return residual <= limit && residual < exact ? (residual, limit) : (exact, radius)
            }.min { $0.0 < $1.0 }!
            return (label, closest.0, closest.1)
        }.sorted { $0.1 < $1.1 }
        let first = ranked[0], second = ranked[1]
        guard first.1 <= first.2 else { return Match(distance: first.1) }
        guard second.1-first.1 >= min(0.10, first.2 * 0.35) else {
            return Match(alternatives: [first.0,second.0], distance: first.1)
        }
        return Match(label: first.0, distance: first.1)
    }
}

/// A movement readout in the user's own taught range, never a probability.
struct ExpressionMovementReading {
    let change: Double
    let fraction: Double?
    static func make(cue: ExpressionCue, observation: ExpressionObservation?,
                     examples: [TaughtExpressionLabel: [ExpressionExample]]) -> Self? {
        guard let value = observation?.values[cue], let index = ExpressionCue.allCases.firstIndex(of: cue),
              let neutral = examples[.neutral], !neutral.isEmpty else { return nil }
        let baseline = neutral.map { $0.center[index] }.reduce(0,+) / Double(neutral.count)
        let change = value-baseline
        guard let label = TaughtExpressionLabel(rawValue: cue.rawValue),
              let taught = examples[label], !taught.isEmpty else { return Self(change: change, fraction: nil) }
        let target = taught.map { $0.center[index] }.reduce(0,+) / Double(taught.count) - baseline
        return Self(change: change, fraction: abs(target) > 0.000001 ? change/target : nil)
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
    var needsSensitivityRetake: Bool { model?.sensitiveGeometry == false }
    var needsNoseScrunchRetake: Bool { profile?.measurement == .upperLip }
    var needsJawDropRetake: Bool { profile != nil && profile?.measurement?.usesJaw != true }
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
        guard observation.measurement == profile.measurement else { clear(.unavailable); return }
        guard profile.camera == observation.camera else { clear(.wrongCamera); return }
        guard observation.pose.isNear(profile.pose) else { clear(.faceForward); return }
        let match = model.match(ExpressionCue.allCases.map { observation.values[$0]! }, jawOpening: observation.jawOpening)
        distance = match.distance
        guard let label = match.label else { clear(match.alternatives.isEmpty ? .unknown : .ambiguous); return }
        if label == .neutral { clear(.neutral); return }
        if pending != label { pending = label; sinceMS = timestampMS }
        result = Double(timestampMS)-Double(sinceMS ?? timestampMS) >= 300 ? .active(label) : .holding(label)
    }
    private mutating func clear(_ state: Result) { pending = nil; sinceMS = nil; result = state }
}
