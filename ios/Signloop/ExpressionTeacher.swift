import Foundation

/// A temporary training session, separate from the installed runtime profile.
/// Two teaching takes plus a fresh validation take for each of six labels.
struct ExpressionTeacher {
    struct Step: Equatable {
        var label: TaughtExpressionLabel
        var take: Int
        var isValidation: Bool
        var title: String { isValidation ? "Check \(label.title.lowercased())" : "Teach \(label.title.lowercased()) · take \(take) of 2" }
    }
    struct Capture {
        let step: Step
        var startMS: Int?
        var observations: [ExpressionObservation] = []
        var timestamps: [Int] = []
        var progress = 0.0
        var preparing = true
    }
    private(set) var examples: [TaughtExpressionLabel: [ExpressionExample]] = [:]
    private(set) var validation: [TaughtExpressionLabel: ExpressionValidation] = [:]
    private(set) var capture: Capture?
    private(set) var message = "Teach your relaxed face and five expressions once. Your existing demo profile stays active until you save the replacement."
    private(set) var candidate: TaughtExpressionProfile?
    private(set) var readyForCapture = false
    private(set) var model: TaughtExpressionModel?
    private var camera: String?
    private var pose: ExpressionPose?
    private var latest: ExpressionObservation?
    var observation: ExpressionObservation? { latest }
    private var lastMS: Int?

    var nextStep: Step? {
        for label in TaughtExpressionLabel.allCases where examples[label, default: []].count < 2 {
            return Step(label: label, take: examples[label, default: []].count+1, isValidation: false)
        }
        guard model != nil else { return nil }
        for label in TaughtExpressionLabel.allCases where validation[label] == nil {
            return Step(label: label, take: 1, isValidation: true)
        }
        return nil
    }
    var completedSteps: Int { examples.values.reduce(0) { $0+$1.count } + validation.count }
    mutating func startCapture() {
        guard readyForCapture, let nextStep, capture == nil else { return }
        capture = Capture(step: nextStep)
        message = "Get ready, then hold your expression steady for two seconds."
    }
    mutating func interrupt() {
        if capture != nil { message = "Capture interrupted. Completed takes are kept; try this take again." }
        capture = nil; latest = nil; lastMS = nil; readyForCapture = false
    }
    mutating func retake(_ label: TaughtExpressionLabel) {
        guard capture == nil else { return }
        // Neutral is the view/camera reference for every other take.
        if label == .neutral { self = Self(); return }
        examples[label] = nil; validation = [:]; model = nil; candidate = nil
        message = "Retake \(label.title.lowercased()). The other teaching examples are kept; all expressions will be checked again."
    }
    mutating func observe(timestampMS: Int, hasFace: Bool, observation: ExpressionObservation?) {
        guard hasFace, timestampMS >= 0, let observation, observation.isValid,
              observation.measurement == .current else { interrupt(); return }
        if let lastMS, timestampMS == lastMS { return }
        if let lastMS, timestampMS < lastMS { interrupt(); return }
        if let lastMS, Double(timestampMS)-Double(lastMS) > 400 { interrupt() }
        lastMS = timestampMS; latest = observation
        if let camera, camera != observation.camera {
            interrupt(); message = "Switch back to the camera used for your relaxed face."; return
        }
        if let pose, !observation.pose.isNear(pose) {
            interrupt(); message = "Face the camera at the angle used for your relaxed face."; return
        }
        readyForCapture = true
        guard var capture else { return }
        if capture.startMS == nil { capture.startMS = timestampMS }
        let elapsed = Double(timestampMS)-Double(capture.startMS!)
        capture.preparing = elapsed < 1000
        capture.progress = max(0,min(1,(elapsed-1000)/2000))
        if !capture.preparing {
            capture.observations.append(observation)
            capture.timestamps.append(timestampMS)
            if capture.observations.count > 120 { capture.observations.removeFirst(); capture.timestamps.removeFirst() }
        }
        self.capture = capture
        guard capture.progress >= 1 else { return }
        self.capture = nil
        finish(capture)
    }
    private mutating func finish(_ capture: Capture) {
        let samples = capture.observations
        guard samples.count >= 12 else { message = "Too few fresh frames. Hold still and retry this take."; return }
        let reference = samples[samples.count/2].pose
        guard samples.allSatisfy({ abs($0.pose.horizontal-reference.horizontal) < 0.04 && abs($0.pose.vertical-reference.vertical) < 0.04 }) else {
            message = "Your head moved during that take. Hold it steady and retry."; return
        }
        let example = ExpressionExample.summarize(samples)
        if capture.step.label == .neutral && example.center[2] < 0.025 {
            message = "Keep your eyes naturally open for your relaxed-face example."; return
        }
        if capture.step.isValidation {
            guard let model else { return }
            let matches = samples.map { sample in
                model.match(ExpressionCue.allCases.map { sample.values[$0]! }).label == capture.step.label
            }
            let accepted = matches.filter { $0 }.count
            var since: Int?, longestHold = 0
            for (index, matchesLabel) in matches.enumerated() {
                if matchesLabel {
                    if since == nil { since = capture.timestamps[index] }
                    longestHold = max(longestHold, capture.timestamps[index] - since!)
                } else { since = nil }
            }
            guard longestHold >= 300, Double(accepted)/Double(samples.count) >= 0.8,
                  model.match(example.center).label == capture.step.label else {
                message = "That repeat did not consistently match \(capture.step.label.title.lowercased()). Try again, or retake its teaching examples below."; return
            }
            validation[capture.step.label] = ExpressionValidation(example: example, accepted: accepted, total: samples.count, longestHoldMS: longestHold)
        } else {
            examples[capture.step.label, default: []].append(example)
            if camera == nil { camera = samples[0].camera; pose = reference }
            if examples.values.reduce(0, { $0+$1.count }) == 12 {
                do { model = try TaughtExpressionModel(examples: examples) }
                catch { message = error.localizedDescription; return }
            }
        }
        message = capture.step.isValidation ? "Check passed. Relax before the next expression." : "Example saved in this setup. Relax before the next take."
        if validation.count == 6, let camera, let pose {
            let completed = TaughtExpressionProfile(id: UUID().uuidString, createdAt: Date(), camera: camera,
                                                   pose: pose, examples: examples, validation: validation)
            do { _ = try completed.validatedModel(); candidate = completed; message = "All six checks passed. Save this as your fixed demo profile." }
            catch { message = error.localizedDescription }
        }
    }
}
