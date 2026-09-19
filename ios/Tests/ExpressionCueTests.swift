import Foundation

@main
struct ExpressionCueTests {
    static var checks = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard value() else { fatalError("FAIL: \(message)") }
    }
    static func signals(_ values: [ExpressionCue: Float] = [:]) -> [String: Float] {
        var result: [String: Float] = [:]
        for cue in ExpressionCue.allCases {
            for channel in cue.channels { result[channel] = values[cue] ?? 0.05 }
        }
        return result
    }
    static func feed(_ engine: inout ExpressionCueEngine, from start: Int, through end: Int,
                     values: [ExpressionCue: Float] = [:]) {
        for time in stride(from: start, through: end, by: 100) {
            engine.observe(timestampMS: time, hasFace: true, coefficients: signals(values))
        }
    }
    static func calibrate(_ engine: inout ExpressionCueEngine,
                          target: ExpressionCalibrationTarget, start: Int,
                          values: [ExpressionCue: Float] = [:]) {
        engine.startCalibration(target)
        feed(&engine, from: start, through: start + 2000, values: values)
    }

    static func main() {
        for cue in ExpressionCue.allCases {
            var engine = ExpressionCueEngine()
            engine.observe(timestampMS: 0, hasFace: true, coefficients: signals([cue: 0.9]))
            expect(engine.decision == .holding(cue), "\(cue): must hold before activation")
            feed(&engine, from: 100, through: 200, values: [cue: 0.9])
            expect(engine.decision == .holding(cue), "\(cue): no early activation")
            feed(&engine, from: 300, through: 500, values: [cue: 0.9])
            expect(engine.decision == .active(cue), "\(cue): sustained cue activates")
            feed(&engine, from: 600, through: 1200)
            expect(engine.decision == .none, "\(cue): relaxing releases")
        }

        var engine = ExpressionCueEngine()
        var asymmetric = signals()
        asymmetric["mouthSmileLeft"] = 0.8
        asymmetric["mouthSmileRight"] = 0.2
        expect(abs(ExpressionCue.joy.score(in: asymmetric)! - 0.5) < 0.0001, "bilateral mean")
        asymmetric.removeValue(forKey: "mouthSmileRight")
        expect(ExpressionCue.joy.score(in: asymmetric) == nil, "missing side is unavailable, never zero")
        for invalid in [Float.nan, .infinity, -0.1, 1.1] {
            var input = signals()
            input["browInnerUp"] = invalid
            engine.observe(timestampMS: 0, hasFace: true, coefficients: input)
            expect(engine.decision == .unavailable, "invalid coefficient rejected")
            engine.resetTracking()
        }

        feed(&engine, from: 0, through: 400, values: [.joy: 0.9])
        expect(engine.decision == .active(.joy), "joy active before ambiguity")
        feed(&engine, from: 500, through: 900, values: [.joy: 0.9, .anger: 0.9])
        expect(engine.decision == .ambiguous([.joy, .anger]), "two cues abstain; no arbitrary winner")
        feed(&engine, from: 1000, through: 1500)
        expect(engine.decision == .none, "neutral is no cue, not a forced emotion")

        engine.resetTracking()
        feed(&engine, from: 0, through: 300, values: [.joy: 0.8])
        feed(&engine, from: 400, through: 1500, values: [.joy: 0.48])
        expect(engine.decision == .active(.joy), "hysteresis keeps active cue above release threshold")
        feed(&engine, from: 1600, through: 2300, values: [.joy: 0.2])
        expect(engine.decision == .none, "below release threshold clears")
        feed(&engine, from: 2400, through: 3000, values: [.joy: 0.48])
        expect(engine.decision == .none, "release threshold does not activate a new cue")

        engine.resetTracking()
        engine.observe(timestampMS: 0, hasFace: true, coefficients: signals([.fear: 0.9]))
        for _ in 0..<30 {
            engine.observe(timestampMS: 0, hasFace: true, coefficients: signals([.fear: 0.9]))
        }
        expect(engine.decision == .holding(.fear), "duplicate frames do not advance hold")
        engine.observe(timestampMS: 1000, hasFace: true, coefficients: signals([.fear: 0.9]))
        expect(engine.decision == .holding(.fear), "large gap restarts hold")
        engine.observe(timestampMS: 900, hasFace: true, coefficients: signals([.fear: 0.9]))
        expect(engine.decision == .unavailable, "backward timestamp clears result")
        feed(&engine, from: 1100, through: 1400, values: [.fear: 0.9])
        engine.observe(timestampMS: 1500, hasFace: false, coefficients: signals([.fear: 0.9]))
        expect(engine.decision == .noFace && engine.raw.isEmpty && engine.levels.isEmpty, "face loss clears all scores")
        engine.observe(timestampMS: 1600, hasFace: true, coefficients: signals([.fear: 0.9]))
        expect(engine.decision == .holding(.fear), "re-entry starts a fresh hold")

        engine.resetTracking()
        feed(&engine, from: 0, through: 300, values: [.sadness: 0.9])
        var incomplete = signals([.sadness: 0.9])
        incomplete.removeValue(forKey: "eyeWideLeft")
        engine.observe(timestampMS: 400, hasFace: true, coefficients: incomplete)
        expect(engine.decision == .unavailable && engine.levels.isEmpty, "partial data cannot win over unknown cues")
        engine.observe(timestampMS: 500, hasFace: true, coefficients: signals([.sadness: 0.9]))
        expect(engine.decision == .holding(.sadness), "missing channel invalidates previous active state")
        engine.setThreshold(0.95, for: .sadness)
        feed(&engine, from: 600, through: 1000, values: [.sadness: 0.9])
        expect(engine.decision == .none, "adjustable per-cue threshold takes effect")
        engine.setThreshold(.nan, for: .sadness)
        expect(engine.threshold(for: .sadness) == 0.95, "nonfinite threshold ignored")
        engine.setThreshold(-1, for: .sadness)
        expect(engine.threshold(for: .sadness) == 0.15, "threshold has a safe lower bound")

        engine = ExpressionCueEngine()
        engine.startCalibration(.baseline)
        expect(engine.calibration == nil, "cannot calibrate without a face")
        engine.observe(timestampMS: 0, hasFace: true, coefficients: signals())
        engine.startCalibration(.cue(.joy))
        expect(engine.calibration == nil, "cue calibration requires a baseline")
        calibrate(&engine, target: .baseline, start: 100)
        expect(engine.hasBaseline && engine.calibration == nil, "two-second relaxed baseline captured")
        expect(abs(engine.baselines[.joy]! - 0.05) < 0.0001, "baseline uses measured score")
        for (index, cue) in ExpressionCue.allCases.enumerated() {
            calibrate(&engine, target: .cue(cue), start: 2200 + index * 2100, values: [cue: 0.65])
            expect(abs(engine.peaks[cue]! - 0.65) < 0.0001, "\(cue): range calibrated independently")
            expect(engine.decision == .none, "calibration never emits an emotion preset")
        }
        feed(&engine, from: 12700, through: 13500)
        feed(&engine, from: 13600, through: 14500, values: [.joy: 0.45])
        expect(engine.decision == .active(.joy), "calibrated range enables a below-default raw score")
        expect(engine.levels[.joy]! > 0.6 && engine.levels[.joy]! < 0.7, "level normalized relative to baseline/range")
        engine.resetTracking()
        expect(engine.hasBaseline && engine.peaks.count == 5, "pause keeps session calibration")
        expect(engine.decision == .noFace, "pause clears the decision")
        engine.observe(timestampMS: 0, hasFace: true, coefficients: signals())
        calibrate(&engine, target: .cue(.joy), start: 100, values: [.joy: 0.08])
        expect(abs(engine.peaks[.joy]! - 0.65) < 0.0001, "weak response never overwrites usable calibration")
        expect(engine.calibrationMessage.contains("barely changed"), "weak channel produces actionable feedback")
        engine.startCalibration(.baseline)
        engine.observe(timestampMS: 2200, hasFace: true, coefficients: signals())
        expect(engine.decision == .calibrating, "calibration suppresses classification")
        engine.observe(timestampMS: 2300, hasFace: false, coefficients: [:])
        expect(engine.calibration == nil && engine.hasBaseline, "face loss aborts capture and keeps previous profile")
        expect(engine.calibrationMessage.contains("interrupted"), "interrupted calibration is explained")
        engine.observe(timestampMS: 2400, hasFace: true, coefficients: signals())
        engine.startCalibration(.baseline)
        engine.observe(timestampMS: 2500, hasFace: true, coefficients: signals())
        engine.observe(timestampMS: 3500, hasFace: true, coefficients: signals())
        expect(engine.calibration == nil, "capture gap aborts calibration")
        engine.startCalibration(.baseline)
        engine.cancelCalibration()
        expect(engine.calibration == nil && engine.hasBaseline, "cancel preserves calibration")
        calibrate(&engine, target: .baseline, start: 3600)
        expect(engine.peaks.isEmpty, "new baseline invalidates old cue ranges")
        engine.resetCalibration()
        expect(!engine.hasBaseline && engine.thresholds.isEmpty && engine.raw.isEmpty, "reset clears profile and readings")
        print("PASS: \(checks) expression checks (five cues, abstention, timing, hysteresis, missing data, calibration)")
    }
}
