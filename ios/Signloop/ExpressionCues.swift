import Foundation

/// Experimental movement-to-preset rules. Scores are not emotion probabilities.
enum ExpressionCue: String, CaseIterable, Identifiable, Codable {
    case joy, anger, fear, sadness, disgust
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var defaultThreshold: Double { 0.15 }
    var rawBounds: ClosedRange<Double> {
        switch self {
        case .joy, .disgust, .fear: return 0...1
        case .anger, .sadness: return -2...2
        }
    }
    // Floors for detector jitter, in each measurement's own units.
    var noiseFloor: Double {
        switch self {
        case .joy, .disgust: return 0.015
        case .anger, .sadness: return 0.008
        case .fear: return 0.003
        }
    }
    var minimumCalibrationRange: Double { noiseFloor * 2 }
    var movement: String {
        switch self {
        case .joy: return "Smile"
        case .anger: return "Lowered brows"
        case .fear: return "Wide eyes"
        case .sadness: return "Raised inner brows"
        case .disgust: return "Non-smiling scrunch"
        }
    }
    var instruction: String {
        switch self {
        case .joy: return "Lift the corners of your mouth."
        case .anger: return "Lower your eyebrows from their relaxed position and draw them together."
        case .fear: return "Open your eyes a little wider than your relaxed face, looking straight ahead."
        case .sadness: return "Lift the inner ends of your eyebrows more than the outer ends."
        case .disgust: return "Make an “ew” face: lift your upper lip and narrow your eyes slightly, without smiling or closing them."
        }
    }
}

enum ExpressionDecision: Equatable {
    case noFace, unavailable, needsBaseline, faceForward, none, calibrating
    case holding(ExpressionCue), active(ExpressionCue), ambiguous([ExpressionCue])
}

enum ExpressionCalibrationTarget: Equatable {
    case baseline
    case cue(ExpressionCue)
    var instruction: String {
        switch self {
        case .baseline: return "Relax your brows and mouth. Keep your eyes naturally open and look straight ahead."
        case .cue(let cue): return cue.instruction
        }
    }
}

struct ExpressionCalibration {
    let target: ExpressionCalibrationTarget
    let camera: String
    var startMS: Int?
    var samples: [ExpressionCue: [Double]] = [:]
    var poses: [ExpressionPose] = []
    var scrunchSamples = 0
    var totalSamples = 0
    var progress = 0.0
}

/// Only completed numeric calibration is persisted, never frames or landmarks.
/// Bump version when measurement units or cue definitions change.
struct ExpressionProfile: Codable, Equatable {
    var version = 1
    var baselines: [ExpressionCue: Double] = [:]
    var noise: [ExpressionCue: Double] = [:]
    var peaks: [ExpressionCue: Double] = [:]
    var thresholds: [ExpressionCue: Double] = [:]
    var pose: ExpressionPose?
    var camera: String?
    var hasBaseline: Bool { baselines.count == ExpressionCue.allCases.count }

    var isValid: Bool {
        guard version == 1,
              thresholds.values.allSatisfy({ $0.isFinite && (0.15...0.95).contains($0) }) else { return false }
        if baselines.isEmpty { return noise.isEmpty && peaks.isEmpty && pose == nil && camera == nil }
        guard hasBaseline, noise.count == ExpressionCue.allCases.count,
              pose?.isValid == true, ["front", "back"].contains(camera ?? "") else { return false }
        return ExpressionCue.allCases.allSatisfy { cue in
            guard let base = baselines[cue], base.isFinite, cue.rawBounds.contains(base),
                  let jitter = noise[cue], jitter.isFinite, (cue.noiseFloor...4).contains(jitter) else { return false }
            if cue == .fear && base < 0.025 { return false }
            if let peak = peaks[cue] {
                return peak.isFinite && cue.rawBounds.contains(peak) && peak-base-jitter >= cue.minimumCalibrationRange
            }
            return true
        }
    }
}

enum ExpressionProfileStore {
    static let key = "expression.personal-profile.v1"
    static func load(from defaults: UserDefaults = .standard) -> ExpressionProfile {
        guard let data = defaults.data(forKey: key),
              let profile = try? JSONDecoder().decode(ExpressionProfile.self, from: data), profile.isValid else {
            return ExpressionProfile()
        }
        return profile
    }
    static func save(_ profile: ExpressionProfile, to defaults: UserDefaults = .standard) {
        guard profile.isValid else { return }
        if profile == ExpressionProfile() { defaults.removeObject(forKey: key); return }
        guard let data = try? JSONEncoder().encode(profile) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Fresh observations advance timers. Personal calibration is independent of
/// tracking resets; no prediction is allowed before a relaxed face is captured.
struct ExpressionCueEngine {
    static let holdMS = 300
    static let maximumGapMS = 400
    static let calibrationMS = 2000
    static let minimumCalibrationSamples = 8
    private(set) var profile: ExpressionProfile
    private(set) var raw: [ExpressionCue: Double] = [:]
    private(set) var levels: [ExpressionCue: Double] = [:]
    private(set) var decision: ExpressionDecision = .noFace
    private(set) var calibration: ExpressionCalibration?
    private(set) var calibrationMessage: String
    private var observation: ExpressionObservation?
    private var lastMS: Int?
    private var pending: ExpressionCue?
    private var pendingSinceMS: Int?
    private var active: ExpressionCue?

    init(profile: ExpressionProfile = ExpressionProfile()) {
        self.profile = profile.isValid ? profile : ExpressionProfile()
        calibrationMessage = self.profile.hasBaseline
            ? "Your relaxed face is saved on this phone. Recapture for a different person or setup."
            : "Capture your relaxed face once. It will be remembered on this phone."
    }
    var baselines: [ExpressionCue: Double] { profile.baselines }
    var peaks: [ExpressionCue: Double] { profile.peaks }
    var thresholds: [ExpressionCue: Double] { profile.thresholds }
    var hasBaseline: Bool { profile.hasBaseline }
    var hasCompleteFace: Bool { observation != nil }
    var canUseBaseline: Bool { hasBaseline && observation?.camera == profile.camera }
    func threshold(for cue: ExpressionCue) -> Double { thresholds[cue] ?? cue.defaultThreshold }
    func releaseThreshold(for cue: ExpressionCue) -> Double { threshold(for: cue) * 0.75 }

    private func range(for cue: ExpressionCue) -> Double {
        if let peak = peaks[cue] {
            return max(cue.minimumCalibrationRange, peak - baselines[cue, default: 0] - profile.noise[cue, default: 0])
        }
        // The eye range scales with YOUR normal eye opening, including small eyes.
        switch cue {
        case .joy: return 0.40
        case .anger: return 0.12
        case .fear: return max(0.02, baselines[.fear, default: 0] * 0.25)
        case .sadness: return 0.10
        case .disgust: return 0.20
        }
    }
    private func instantLevel(for cue: ExpressionCue) -> Double {
        let delta = raw[cue, default: 0] - baselines[cue, default: 0] - profile.noise[cue, default: 0]
        return min(1, max(0, delta / range(for: cue)))
    }
    private var isScrunch: Bool {
        let neutralEyes = baselines[.fear, default: 0]
        let eyes = raw[.fear, default: 0]
        let narrowing = max(profile.noise[.fear, default: 0], neutralEyes * 0.06)
        // Lip lift alone is insufficient. Reject blinks/closed eyes, and block
        // smiles before the hold timer (also while a smile is smoothing away).
        return neutralEyes > 0 && eyes <= neutralEyes - narrowing && eyes >= neutralEyes * 0.55 &&
            instantLevel(for: .joy) < 0.10 && levels[.joy, default: 0] < 0.10
    }

    mutating func setThreshold(_ value: Double, for cue: ExpressionCue) {
        guard value.isFinite else { return }
        profile.thresholds[cue] = min(0.95, max(0.15, value))
        clearDecision()
        decision = idleDecision
    }
    mutating func resetCalibration() { self = ExpressionCueEngine() }
    mutating func resetTracking() {
        if calibration != nil { calibrationMessage = "Capture interrupted. Try again with your face in view." }
        calibration = nil
        observation = nil
        raw.removeAll(keepingCapacity: true)
        levels.removeAll(keepingCapacity: true)
        lastMS = nil
        clearDecision()
        decision = .noFace
    }
    private var idleDecision: ExpressionDecision {
        !hasCompleteFace ? .noFace : (!canUseBaseline ? .needsBaseline : .none)
    }
    mutating func startCalibration(_ target: ExpressionCalibrationTarget) {
        guard let observation, calibration == nil else { return }
        if case .cue = target, !canUseBaseline { return }
        clearDecision()
        levels.removeAll(keepingCapacity: true)
        calibration = ExpressionCalibration(target: target, camera: observation.camera)
        calibrationMessage = target.instruction
        decision = .calibrating
    }
    mutating func cancelCalibration() {
        calibration = nil
        calibrationMessage = "Capture cancelled. Previous calibration kept."
        clearDecision()
        decision = idleDecision
    }

    mutating func observe(timestampMS: Int, hasFace: Bool, observation next: ExpressionObservation?) {
        guard hasFace, timestampMS >= 0 else { resetTracking(); return }
        if let lastMS, timestampMS == lastMS { return }
        if let lastMS, timestampMS < lastMS {
            resetTracking(); decision = .unavailable; return
        }
        if let lastMS, Double(timestampMS) - Double(lastMS) > Double(Self.maximumGapMS) { resetTracking() }
        if let previous = observation, let next, previous.camera != next.camera { resetTracking() }
        let elapsed = lastMS.map { Double(timestampMS) - Double($0) }
        lastMS = timestampMS
        guard let next, next.isValid else {
            resetTracking(); decision = .unavailable; return
        }
        observation = next
        raw = next.values
        if calibration?.target != .baseline, canUseBaseline,
           let pose = profile.pose, !next.pose.isNear(pose) {
            if calibration != nil { calibrationMessage = "Head angle changed. Face the camera and try again." }
            calibration = nil
            levels.removeAll(keepingCapacity: true)
            clearDecision(); decision = .faceForward; return
        }
        if calibration != nil { collectCalibration(at: timestampMS); return }
        guard canUseBaseline else {
            levels.removeAll(keepingCapacity: true)
            clearDecision(); decision = .needsBaseline; return
        }
        let alpha = elapsed.map { 1 - exp(-$0 / 120) } ?? 1
        for cue in ExpressionCue.allCases {
            let value = instantLevel(for: cue)
            levels[cue] = levels[cue].map { $0 + alpha * (value - $0) } ?? value
        }
        // An invalid scrunch releases immediately; never smooth its lip-only
        // score into a valid disgust decision during a smile or a blink.
        if !isScrunch { levels[.disgust] = 0 }
        var matching = ExpressionCue.allCases.filter {
            levels[$0, default: 0] >= (active == $0 ? releaseThreshold(for: $0) : threshold(for: $0))
        }
        if matching.count > 1 {
            let ranked = matching.sorted { levels[$0, default: 0] > levels[$1, default: 0] }
            let first = levels[ranked[0], default: 0], second = levels[ranked[1], default: 0]
            // Facial movements overlap. A faint secondary response should not
            // veto a clear cue; comparable responses still abstain. These are
            // heuristic movement margins, not calibrated emotion confidence.
            if first - second >= 0.20 && first >= second * 1.8 { matching = [ranked[0]] }
        }
        guard matching.count == 1, let cue = matching.first else {
            clearDecision(); decision = matching.isEmpty ? .none : .ambiguous(matching); return
        }
        if active == cue { decision = .active(cue); return }
        active = nil
        if pending != cue { pending = cue; pendingSinceMS = timestampMS }
        if Double(timestampMS) - Double(pendingSinceMS ?? timestampMS) >= Double(Self.holdMS) {
            active = cue; pending = nil; pendingSinceMS = nil; decision = .active(cue)
        } else { decision = .holding(cue) }
    }

    private mutating func clearDecision() { active = nil; pending = nil; pendingSinceMS = nil }
    private mutating func collectCalibration(at timestampMS: Int) {
        guard var capture = calibration, let observation else { return }
        guard capture.camera == observation.camera else { cancelCalibration(); return }
        if capture.startMS == nil { capture.startMS = timestampMS }
        for cue in ExpressionCue.allCases {
            capture.samples[cue, default: []].append(raw[cue]!)
            if capture.samples[cue]!.count > 120 { capture.samples[cue]!.removeFirst() }
        }
        capture.poses.append(observation.pose)
        if capture.poses.count > 120 { capture.poses.removeFirst() }
        capture.totalSamples += 1
        if isScrunch { capture.scrunchSamples += 1 }
        capture.progress = min(1, (Double(timestampMS) - Double(capture.startMS!)) / Double(Self.calibrationMS))
        calibration = capture
        decision = .calibrating
        guard capture.progress >= 1 else { return }
        calibration = nil
        defer { levels.removeAll(keepingCapacity: true); clearDecision(); decision = idleDecision }
        guard capture.samples.values.allSatisfy({ $0.count >= Self.minimumCalibrationSamples }) else {
            calibrationMessage = "Too few fresh frames. Hold still and try again."; return
        }
        func percentile(_ values: [Double], _ fraction: Double) -> Double {
            let sorted = values.sorted()
            return sorted[Int(Double(sorted.count - 1) * fraction)]
        }
        switch capture.target {
        case .baseline:
            let pose = ExpressionPose(horizontal: percentile(capture.poses.map(\.horizontal), 0.5),
                                      vertical: percentile(capture.poses.map(\.vertical), 0.5))
            guard capture.poses.allSatisfy({ abs($0.horizontal-pose.horizontal) < 0.04 && abs($0.vertical-pose.vertical) < 0.04 }),
                  percentile(capture.samples[.fear]!, 0.5) >= 0.025 else {
                calibrationMessage = "Keep your head still and your eyes naturally open, then recapture. Previous profile kept."; return
            }
            var updated = profile
            updated.baselines = [:]; updated.noise = [:]; updated.peaks = [:]
            for cue in ExpressionCue.allCases {
                let samples = capture.samples[cue]!
                let base = percentile(samples, 0.5)
                updated.baselines[cue] = base
                // Only change above neutral activates a cue. In particular,
                // a blink during capture must not inflate the eye-wide range.
                updated.noise[cue] = max(cue.noiseFloor, 1.5 * (percentile(samples, 0.9) - base))
            }
            let stable = ExpressionCue.allCases.allSatisfy { cue in
                let limit: Double
                switch cue {
                case .joy, .disgust: limit = 0.20
                case .anger, .sadness: limit = 0.10
                case .fear: limit = max(0.012, updated.baselines[.fear, default: 0] * 0.20)
                }
                return updated.noise[cue, default: 0] <= limit
            }
            guard stable else {
                calibrationMessage = "Your expression changed during capture. Relax, hold still and try again. Previous profile kept."; return
            }
            updated.pose = pose; updated.camera = capture.camera
            guard updated.isValid else { return }
            profile = updated
            calibrationMessage = "Your relaxed face is saved on this phone. Try each cue; calibrate its range if needed."
        case .cue(let cue):
            if cue == .disgust && Double(capture.scrunchSamples) / Double(capture.totalSamples) < 0.8 {
                calibrationMessage = "For disgust, narrow your eyes slightly and lift your upper lip without smiling. Previous range kept."; return
            }
            let samples = capture.samples[cue]!
            let peak = percentile(samples, 0.5)
            let start = baselines[cue, default: 0] + profile.noise[cue, default: 0]
            guard percentile(samples, 0.1) - start >= cue.minimumCalibrationRange else {
                calibrationMessage = "\(cue.movement) barely changed beyond your resting variation. Hold the movement steadily and try again; previous range kept."; return
            }
            profile.peaks[cue] = peak
            calibrationMessage = "\(cue.movement) range saved on this phone. Relax, then try it again."
        }
    }
}
