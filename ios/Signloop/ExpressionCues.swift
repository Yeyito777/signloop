import Foundation

/// Experimental movement-to-preset rules. Scores are not emotion probabilities.
enum ExpressionCue: String, CaseIterable, Identifiable {
    case joy, anger, fear, sadness, disgust
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var movement: String {
        switch self {
        case .joy: return "Smile"
        case .anger: return "Lowered brows"
        case .fear: return "Wide eyes"
        case .sadness: return "Raised inner brows"
        case .disgust: return "Raised upper lip"
        }
    }
    var instruction: String {
        switch self {
        case .joy: return "Lift the corners of your mouth."
        case .anger: return "Lower your eyebrows and draw them together."
        case .fear: return "Open your eyes wider while looking straight ahead."
        case .sadness: return "Lift the inner ends of your eyebrows."
        case .disgust: return "Lift your upper lip, as if saying “ew.”"
        }
    }
    var channels: [String] {
        switch self {
        case .joy: return ["mouthSmileLeft", "mouthSmileRight"]
        case .anger: return ["browDownLeft", "browDownRight"]
        case .fear: return ["eyeWideLeft", "eyeWideRight"]
        case .sadness: return ["browInnerUp"]
        case .disgust: return ["mouthUpperUpLeft", "mouthUpperUpRight"]
        }
    }
    func score(in coefficients: [String: Float]) -> Double? {
        let values = channels.compactMap { coefficients[$0].map(Double.init) }
        guard values.count == channels.count,
              values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}

enum ExpressionDecision: Equatable {
    case noFace, unavailable, none, calibrating
    case holding(ExpressionCue), active(ExpressionCue), ambiguous([ExpressionCue])
}

enum ExpressionCalibrationTarget: Equatable {
    case baseline
    case cue(ExpressionCue)
    var instruction: String {
        switch self {
        case .baseline: return "Relax your face and look straight ahead."
        case .cue(let cue): return cue.instruction
        }
    }
}

struct ExpressionCalibration {
    let target: ExpressionCalibrationTarget
    var startMS: Int?
    var samples: [ExpressionCue: [Double]] = [:]
    var progress = 0.0
}

/// Pure, bounded state machine; only fresh face observations advance timers.
/// Calibration and thresholds live in memory, separately from detection state.
struct ExpressionCueEngine {
    static let holdMS = 300
    static let maximumGapMS = 400
    static let calibrationMS = 2000
    static let minimumCalibrationSamples = 8
    static let minimumRange = 0.10
    static let releaseMargin = 0.12

    private(set) var raw: [ExpressionCue: Double] = [:]
    private(set) var levels: [ExpressionCue: Double] = [:]
    private(set) var baselines: [ExpressionCue: Double] = [:]
    private(set) var peaks: [ExpressionCue: Double] = [:]
    private(set) var thresholds: [ExpressionCue: Double] = [:]
    private(set) var decision: ExpressionDecision = .noFace
    private(set) var calibration: ExpressionCalibration?
    private(set) var calibrationMessage = "Start with a relaxed baseline, then calibrate each cue."
    private var lastMS: Int?
    private var pending: ExpressionCue?
    private var pendingSinceMS: Int?
    private var active: ExpressionCue?

    var hasBaseline: Bool { baselines.count == ExpressionCue.allCases.count }
    var hasCompleteFace: Bool { raw.count == ExpressionCue.allCases.count }
    func threshold(for cue: ExpressionCue) -> Double { thresholds[cue] ?? 0.55 }
    func releaseThreshold(for cue: ExpressionCue) -> Double {
        max(0, threshold(for: cue) - Self.releaseMargin)
    }

    mutating func setThreshold(_ value: Double, for cue: ExpressionCue) {
        guard value.isFinite else { return }
        thresholds[cue] = min(0.95, max(0.15, value))
        clearDecision()
        decision = hasCompleteFace ? .none : .noFace
    }

    mutating func resetCalibration() {
        self = ExpressionCueEngine()
        calibrationMessage = "Calibration and thresholds reset."
    }

    /// Pause, face loss, dismissal and camera switches invalidate pending work.
    mutating func resetTracking() {
        if calibration != nil { calibrationMessage = "Capture interrupted. Try again with your face in view." }
        calibration = nil
        raw.removeAll(keepingCapacity: true)
        levels.removeAll(keepingCapacity: true)
        lastMS = nil
        clearDecision()
        decision = .noFace
    }

    mutating func startCalibration(_ target: ExpressionCalibrationTarget) {
        guard hasCompleteFace, calibration == nil else { return }
        if case .cue = target, !hasBaseline { return }
        clearDecision()
        calibration = ExpressionCalibration(target: target)
        calibrationMessage = target.instruction
        decision = .calibrating
    }

    mutating func cancelCalibration() {
        calibration = nil
        calibrationMessage = "Capture cancelled. Previous calibration kept."
        clearDecision()
        decision = hasCompleteFace ? .none : .noFace
    }

    mutating func observe(timestampMS: Int, hasFace: Bool, coefficients: [String: Float]) {
        guard hasFace, timestampMS >= 0 else { resetTracking(); return }
        // Repeated publications never count as additional hold/calibration time.
        if let lastMS, timestampMS == lastMS { return }
        if let lastMS, timestampMS < lastMS {
            resetTracking()
            decision = .unavailable
            return
        }
        let gap = lastMS.map { Double(timestampMS) - Double($0) }
        if let gap, gap > Double(Self.maximumGapMS) { resetTracking() }
        let elapsed = lastMS.map { Double(timestampMS) - Double($0) }
        lastMS = timestampMS
        raw = Dictionary(uniqueKeysWithValues: ExpressionCue.allCases.compactMap { cue in
            cue.score(in: coefficients).map { (cue, $0) }
        })
        guard hasCompleteFace else {
            if calibration != nil { calibrationMessage = "A face signal is missing. Capture interrupted." }
            calibration = nil
            levels.removeAll(keepingCapacity: true)
            clearDecision()
            decision = .unavailable
            return
        }
        // Time-based smoothing behaves consistently across camera frame rates.
        let alpha = elapsed.map { 1 - exp(-$0 / 120) } ?? 1
        for cue in ExpressionCue.allCases {
            let baseline = baselines[cue] ?? 0
            let range = max(Self.minimumRange, (peaks[cue] ?? 1) - baseline)
            let value = min(1, max(0, (raw[cue]! - baseline) / range))
            levels[cue] = levels[cue].map { $0 + alpha * (value - $0) } ?? value
        }
        if calibration != nil {
            collectCalibration(at: timestampMS)
            return
        }
        let matching = ExpressionCue.allCases.filter { cue in
            levels[cue, default: 0] >= (active == cue ? releaseThreshold(for: cue) : threshold(for: cue))
        }
        guard matching.count == 1, let cue = matching.first else {
            clearDecision()
            decision = matching.isEmpty ? .none : .ambiguous(matching)
            return
        }
        if active == cue { decision = .active(cue); return }
        active = nil
        if pending != cue {
            pending = cue
            pendingSinceMS = timestampMS
        }
        if Double(timestampMS) - Double(pendingSinceMS ?? timestampMS) >= Double(Self.holdMS) {
            active = cue
            pending = nil
            pendingSinceMS = nil
            decision = .active(cue)
        } else {
            decision = .holding(cue)
        }
    }

    private mutating func clearDecision() {
        active = nil
        pending = nil
        pendingSinceMS = nil
    }

    private mutating func collectCalibration(at timestampMS: Int) {
        guard var capture = calibration else { return }
        if capture.startMS == nil { capture.startMS = timestampMS }
        for cue in ExpressionCue.allCases {
            capture.samples[cue, default: []].append(raw[cue]!)
            if capture.samples[cue]!.count > 120 { capture.samples[cue]!.removeFirst() }
        }
        capture.progress = min(1, (Double(timestampMS) - Double(capture.startMS!)) / Double(Self.calibrationMS))
        calibration = capture
        decision = .calibrating
        guard capture.progress >= 1 else { return }
        calibration = nil
        guard capture.samples.values.allSatisfy({ $0.count >= Self.minimumCalibrationSamples }) else {
            calibrationMessage = "Too few fresh frames. Hold still and try again."
            decision = .none
            return
        }
        func percentile(_ cue: ExpressionCue, _ fraction: Double) -> Double {
            let values = capture.samples[cue]!.sorted()
            return values[Int(Double(values.count - 1) * fraction)]
        }
        switch capture.target {
        case .baseline:
            baselines = Dictionary(uniqueKeysWithValues: ExpressionCue.allCases.map { ($0, percentile($0, 0.5)) })
            peaks.removeAll()
            calibrationMessage = "Relaxed baseline saved. Now capture each cue at a comfortable strength."
        case .cue(let cue):
            let peak = percentile(cue, 0.9)
            guard peak - baselines[cue, default: 0] >= Self.minimumRange else {
                calibrationMessage = "\(cue.movement) barely changed. Try again; the previous range is unchanged."
                decision = .none
                return
            }
            peaks[cue] = peak
            calibrationMessage = "\(cue.movement) range saved. Relax, then try the cue again."
        }
        levels.removeAll(keepingCapacity: true)
        clearDecision()
        decision = .none
    }
}
