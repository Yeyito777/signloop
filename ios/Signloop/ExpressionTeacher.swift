import Foundation

/// A temporary training session, separate from the installed runtime profile.
/// Two teaching takes plus a fresh validation take for each of six labels.
struct ExpressionTeacher {
    enum Status: String, Codable {
        case needsExamples, needsRetake, retryCapture, checksBlocked, checkPending, checkFailed, passed
        var title: String {
            switch self {
            case .needsExamples: return "Teaching incomplete"
            case .needsRetake: return "Teaching needs a retake"
            case .retryCapture: return "Take needs a retry"
            case .checksBlocked: return "Check waiting for teaching"
            case .checkPending: return "Check not run yet"
            case .checkFailed: return "Check failed"
            case .passed: return "Check passed"
            }
        }
    }
    struct Failure: Codable {
        let status: Status
        let reason: String
    }
    struct Step: Equatable {
        var label: TaughtExpressionLabel
        var take: Int
        var isValidation: Bool
        var checkNumber: Int { TaughtExpressionLabel.allCases.firstIndex(of: label)! + 1 }
        var title: String { isValidation ? "Check \(checkNumber) of 6: \(label.title)" : "Teach \(label.title.lowercased()) · take \(take) of 2" }
        var instruction: String { isValidation ? label.checkInstruction : label.instruction }
        var timingInstruction: String { "Tap to start. Get ready for 1 second, then hold still for 2 seconds. Relax when the take finishes." }
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
    private(set) var failures: [TaughtExpressionLabel: Failure] = [:]
    private(set) var capture: Capture?
    private(set) var message = "Teach your relaxed face and five expressions once. Your existing demo profile stays active until you save the replacement."
    private(set) var candidate: TaughtExpressionProfile?
    private(set) var readyForCapture = false
    private(set) var readinessInstruction = "Look straight at the camera with your whole face visible."
    private(set) var model: TaughtExpressionModel?
    private var camera: String?
    private var pose: ExpressionPose?
    private var latest: ExpressionObservation?
    var observation: ExpressionObservation? { latest }
    private var lastMS: Int?

    /// Portable progress, deliberately distinct from an installable checked profile.
    /// Only completed numeric takes are exported, never live frames or camera images.
    struct SetupExport: Codable {
        var format = "honk-and-tell-expression-setup"
        var version = 1
        var measurementVersion = ExpressionMeasurement.current.rawValue
        var exportedAt = Date()
        var camera: String?
        var pose: ExpressionPose?
        var examples: [TaughtExpressionLabel: [ExpressionExample]]
        var validation: [TaughtExpressionLabel: ExpressionValidation]
        var failures: [TaughtExpressionLabel: Failure]
    }
    func exportSetup() throws -> Data {
        let snapshot = SetupExport(camera: camera, pose: pose, examples: examples, validation: validation, failures: failures)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snapshot)
    }
    static func isSetupExport(_ data: Data) -> Bool {
        struct Header: Decodable { var format: String? }
        return (try? JSONDecoder().decode(Header.self, from: data).format) == "honk-and-tell-expression-setup"
    }
    static func restoreSetup(_ data: Data) throws -> Self {
        guard data.count <= 262_144 else { throw ExpressionTeachingError(message: "Setup file is too large.") }
        let saved = try JSONDecoder().decode(SetupExport.self, from: data)
        guard saved.format == "honk-and-tell-expression-setup", saved.version == 1,
              saved.measurementVersion == ExpressionMeasurement.current.rawValue,
              saved.exportedAt.timeIntervalSince1970.isFinite,
              saved.examples.values.allSatisfy({ takes in
                  (1...2).contains(takes.count) && takes.allSatisfy { example in
                      example.isValid && example.jawOpening != nil &&
                      zip(ExpressionCue.allCases, example.center).allSatisfy { ExpressionMeasurement.current.bounds(for: $0).contains($1) }
                  }
              }),
              saved.failures.allSatisfy({ label, failure in
                  [.needsRetake, .retryCapture, .checkFailed].contains(failure.status) &&
                  !failure.reason.isEmpty && failure.reason.count <= 2_000 && saved.validation[label] == nil
              }) else { throw ExpressionTeachingError(message: "This setup file is incomplete, invalid, or uses older measurements. Your current setup is unchanged.") }
        if saved.examples.isEmpty {
            guard saved.camera == nil, saved.pose == nil, saved.validation.isEmpty else {
                throw ExpressionTeachingError(message: "Empty setup has unexpected saved references.")
            }
        } else {
            guard saved.examples[.neutral] != nil, ["front", "back"].contains(saved.camera ?? ""), saved.pose?.isValid == true else {
                throw ExpressionTeachingError(message: "This setup is missing its relaxed-face camera reference.")
            }
        }
        var restored = Self()
        restored.examples = saved.examples; restored.camera = saved.camera; restored.pose = saved.pose
        restored.failures = saved.failures
        if restored.teachingTakeCount == 12 {
            do { restored.model = try TaughtExpressionModel(examples: restored.examples) }
            catch {
                restored.fail(error.localizedDescription, labels: (error as? ExpressionTeachingError)?.affectedLabels ?? [], status: .needsRetake)
            }
        }
        for (label, check) in saved.validation {
            guard let model = restored.model, check.isValid,
                  model.match(check.example.center, jawOpening: check.example.jawOpening).label == label else {
                throw ExpressionTeachingError(message: "The saved \(label.title.lowercased()) check does not match this setup. Your current setup is unchanged.")
            }
        }
        restored.validation = saved.validation
        if restored.validation.count == 6, let camera = restored.camera, let pose = restored.pose {
            let profile = TaughtExpressionProfile(id: UUID().uuidString, createdAt: Date(), camera: camera,
                pose: pose, examples: restored.examples, validation: restored.validation)
            _ = try profile.validatedModel()
            restored.candidate = profile
        }
        restored.message = "Setup restored: \(restored.teachingTakeCount)/12 teaching captures and \(restored.validation.count)/6 checks passed. Follow the next step below."
        return restored
    }

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
    var teachingTakeCount: Int { examples.values.reduce(0) { $0+$1.count } }
    var attentionLabels: [TaughtExpressionLabel] { TaughtExpressionLabel.allCases.filter { failures[$0] != nil } }
    func status(for label: TaughtExpressionLabel) -> Status {
        if let failure = failures[label] { return failure.status }
        if validation[label] != nil { return .passed }
        if examples[label, default: []].count < 2 { return .needsExamples }
        return model == nil ? .checksBlocked : .checkPending
    }
    private mutating func fail(_ reason: String, labels: [TaughtExpressionLabel], status: Status) {
        message = reason
        for label in labels { failures[label] = Failure(status: status, reason: reason) }
    }
    mutating func startCapture() {
        guard readyForCapture, let nextStep, capture == nil else { return }
        capture = Capture(step: nextStep)
        message = "Get ready, then hold your expression steady for two seconds."
    }
    mutating func interrupt() {
        if let capture {
            fail("\(capture.step.label.title) capture interrupted. Completed takes are kept; try this take again.",
                 labels: [capture.step.label], status: .retryCapture)
        }
        capture = nil; latest = nil; lastMS = nil; readyForCapture = false
        readinessInstruction = "Look straight at the camera with your whole face visible."
    }
    mutating func retake(_ label: TaughtExpressionLabel) {
        guard capture == nil else { return }
        // Neutral is the view/camera reference for every other take.
        if label == .neutral { self = Self(); return }
        examples[label] = nil; validation = [:]; failures = [:]; model = nil; candidate = nil
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
            interrupt(); message = "Switch back to the camera used for your relaxed face."
            readinessInstruction = message; return
        }
        if let pose, !observation.pose.isNear(pose) {
            interrupt(); message = "Face the camera at the angle used for your relaxed face."
            readinessInstruction = message; return
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
        guard samples.count >= 12 else {
            fail("Too few fresh frames. Hold still and retry this take.", labels: [capture.step.label], status: .retryCapture)
            return
        }
        let reference = samples[samples.count/2].pose
        guard samples.allSatisfy({ abs($0.pose.horizontal-reference.horizontal) < 0.04 && abs($0.pose.vertical-reference.vertical) < 0.04 }) else {
            fail("Your head moved during that take. Hold it steady and retry.", labels: [capture.step.label], status: .retryCapture)
            return
        }
        let example = ExpressionExample.summarize(samples)
        if capture.step.isValidation {
            guard let model else { return }
            let predicted = samples.map { sample in
                model.match(ExpressionCue.allCases.map { sample.values[$0]! }, jawOpening: sample.jawOpening).label
            }
            let matches = predicted.map { $0 == capture.step.label }
            let accepted = matches.filter { $0 }.count
            var since: Int?, longestHold = 0
            for (index, matchesLabel) in matches.enumerated() {
                if matchesLabel {
                    if since == nil { since = capture.timestamps[index] }
                    longestHold = max(longestHold, capture.timestamps[index] - since!)
                } else { since = nil }
            }
            guard longestHold >= 300, Double(accepted)/Double(samples.count) >= 0.8,
                  model.match(example.center, jawOpening: example.jawOpening).label == capture.step.label else {
                let other = TaughtExpressionLabel.allCases.filter { $0 != capture.step.label }
                    .map { label in (label, predicted.filter { $0 == label }.count) }.max { $0.1 < $1.1 }
                let reason: String
                if let other, other.1 > accepted {
                    reason = "This check matched \(other.0.title.lowercased()) more often than \(capture.step.label.title.lowercased())."
                } else {
                    reason = "This check did not consistently hold \(capture.step.label.title.lowercased())."
                }
                fail("\(reason) Retry the check, or retake this expression's teaching examples.",
                     labels: [capture.step.label], status: .checkFailed)
                return
            }
            validation[capture.step.label] = ExpressionValidation(example: example, accepted: accepted, total: samples.count, longestHoldMS: longestHold)
            failures[capture.step.label] = nil
        } else {
            examples[capture.step.label, default: []].append(example)
            failures[capture.step.label] = nil
            if camera == nil { camera = samples[0].camera; pose = reference }
            if examples.values.reduce(0, { $0+$1.count }) == 12 {
                do { model = try TaughtExpressionModel(examples: examples); failures = [:] }
                catch {
                    let labels = (error as? ExpressionTeachingError)?.affectedLabels ?? []
                    fail(error.localizedDescription, labels: labels, status: .needsRetake)
                    return
                }
            }
        }
        message = capture.step.isValidation ? "\(capture.step.label.title) check passed. Relax before the next expression." : "\(capture.step.label.title) example saved. Relax before the next take."
        if validation.count == 6, let camera, let pose {
            let completed = TaughtExpressionProfile(id: UUID().uuidString, createdAt: Date(), camera: camera,
                                                   pose: pose, examples: examples, validation: validation)
            do { _ = try completed.validatedModel(); candidate = completed; message = "All six checks passed. Save this as your fixed demo profile." }
            catch { message = error.localizedDescription }
        }
    }
}
