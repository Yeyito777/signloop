import Foundation

@main
struct TaughtExpressionTests {
    static var checks = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1; guard value() else { fatalError("FAIL: \(message)") }
    }
    static func rejects(_ message: String, _ operation: () throws -> Void) {
        checks += 1
        do { try operation(); fatalError("FAIL: \(message)") } catch { }
    }
    static func sample(_ label: TaughtExpressionLabel, delta: Double = 0) -> ExpressionObservation {
        let vector: [Double]
        switch label {
        case .neutral: vector = [0.05,-0.70,0.12,0.20,0.05]
        case .joy: vector = [0.65,-0.72,0.10,0.21,0.65]
        case .anger: vector = [0.08,-0.50,0.10,0.15,0.06]
        case .fear: vector = [0.07,-0.78,0.15,0.20,0.08]
        case .sadness: vector = [0.05,-0.78,0.11,0.38,0.05]
        case .disgust: vector = [0.08,-0.64,0.09,0.16,0.65]
        }
        return ExpressionObservation(values: Dictionary(uniqueKeysWithValues: zip(ExpressionCue.allCases,vector.map { $0+delta })),
                                     pose: ExpressionPose(horizontal: 0, vertical: 0.25), camera: "front")
    }
    static func take(_ teacher: inout ExpressionTeacher, label: TaughtExpressionLabel, time: inout Int) {
        time += 100
        teacher.observe(timestampMS: time, hasFace: true, observation: sample(label))
        teacher.startCapture()
        for index in 0...30 {
            time += 100
            teacher.observe(timestampMS: time, hasFace: true,
                            observation: sample(label, delta: index.isMultiple(of: 2) ? 0.001 : -0.001))
        }
    }
    static func taught() -> TaughtExpressionProfile {
        var teacher = ExpressionTeacher(), time = 0
        for label in TaughtExpressionLabel.allCases {
            for _ in 0..<2 { take(&teacher, label: label, time: &time) }
        }
        expect(teacher.completedSteps == 12 && teacher.model != nil && teacher.candidate == nil,
               "teaching alone cannot install an unvalidated profile")
        for label in TaughtExpressionLabel.allCases { take(&teacher, label: label, time: &time) }
        expect(teacher.completedSteps == 18 && teacher.candidate != nil, "one full setup produces a checked profile")
        return teacher.candidate!
    }
    static func main() throws {
        let profile = taught(), model = try profile.validatedModel()
        for label in TaughtExpressionLabel.allCases {
            let vector = ExpressionCue.allCases.map { sample(label,delta: 0.003).values[$0]! }
            expect(model.match(vector).label == label, "\(label): fresh measurements match the taught pattern")
        }
        expect(sample(.joy).values[.disgust] == sample(.disgust).values[.disgust], "smile/disgust fixture deliberately shares upper-lip lift")
        var runtime = TaughtExpressionRuntime(profile: profile)
        for label in TaughtExpressionLabel.allCases {
            runtime.resetTracking()
            runtime.observe(timestampMS: 0, hasFace: true, observation: sample(label))
            expect(runtime.result == (label == .neutral ? .neutral : .holding(label)), "\(label): neutral clears, expression waits")
            for time in stride(from: 100, through: 400, by: 100) { runtime.observe(timestampMS: time, hasFace: true, observation: sample(label)) }
            expect(runtime.result == (label == .neutral ? .neutral : .active(label)), "\(label): stable taught expression activates")
            expect(runtime.profile == profile, "classification never learns over the fixed profile")
            runtime.observe(timestampMS: 500, hasFace: true, observation: sample(.neutral))
            expect(runtime.result == .neutral, "neutral immediately releases every active expression")
        }
        var unknown = sample(.neutral)
        unknown.values[.joy] = 1; unknown.values[.anger] = 1; unknown.values[.sadness] = -1
        runtime.observe(timestampMS: 600, hasFace: true, observation: unknown)
        expect(runtime.result == .unknown, "unseen expression is not forced into an emotion")
        runtime.observe(timestampMS: 700, hasFace: true, observation: sample(.joy))
        for _ in 0..<20 { runtime.observe(timestampMS: 700, hasFace: true, observation: sample(.joy)) }
        expect(runtime.result == .holding(.joy), "duplicate frames do not advance holds")
        runtime.observe(timestampMS: 1700, hasFace: true, observation: sample(.joy))
        expect(runtime.result == .holding(.joy), "long gap starts a fresh hold")
        runtime.observe(timestampMS: 1600, hasFace: true, observation: sample(.joy))
        expect(runtime.result == .unavailable, "backward capture time invalidates result")
        runtime.observe(timestampMS: 1800, hasFace: false, observation: nil)
        expect(runtime.result == .noFace && runtime.profile == profile, "face loss preserves the installed profile")
        var rear = sample(.joy); rear.camera = "back"
        runtime.observe(timestampMS: 1900, hasFace: true, observation: rear)
        expect(runtime.result == .wrongCamera, "profile does not silently switch cameras")
        var turn = sample(.joy); turn.pose.horizontal = 0.3
        runtime.observe(timestampMS: 2000, hasFace: true, observation: turn)
        expect(runtime.result == .faceForward, "large view change abstains")
        var malformed = sample(.joy); malformed.values[.fear] = .nan
        runtime.observe(timestampMS: 2100, hasFace: true, observation: malformed)
        expect(runtime.result == .unavailable, "invalid measurements abstain")
        var blank = TaughtExpressionRuntime()
        blank.observe(timestampMS: 0, hasFace: true, observation: sample(.joy))
        expect(blank.result == .noProfile, "no generic rule fallback before a complete taught profile")

        var teacher = ExpressionTeacher(), time = 0
        teacher.startCapture()
        expect(teacher.capture == nil, "teaching cannot capture without a fresh face")
        teacher.observe(timestampMS: 0, hasFace: true, observation: sample(.neutral))
        teacher.startCapture()
        for stamp in stride(from: 100, through: 900, by: 100) { teacher.observe(timestampMS: stamp, hasFace: true, observation: sample(.neutral)) }
        expect(teacher.capture?.observations.isEmpty == true, "preparation frames are excluded")
        teacher.observe(timestampMS: 1000, hasFace: false, observation: nil)
        expect(teacher.capture == nil && teacher.completedSteps == 0, "lost face aborts unfinished take")
        time = 1100
        take(&teacher, label: .neutral, time: &time)
        expect(teacher.completedSteps == 1, "first complete take retained")
        teacher.startCapture()
        teacher.observe(timestampMS: time+1000, hasFace: true, observation: sample(.neutral))
        expect(teacher.capture == nil && teacher.completedSteps == 1, "capture gap keeps completed takes only")
        teacher.interrupt()
        expect(teacher.completedSteps == 1 && !teacher.readyForCapture, "pause keeps training draft but needs fresh observations")
        teacher = ExpressionTeacher(); time = 0
        for label in TaughtExpressionLabel.allCases { for _ in 0..<2 { take(&teacher,label: label,time: &time) } }
        let frozenExamples = teacher.examples
        var flickering = teacher
        var flickerTime = time + 100
        flickering.observe(timestampMS: flickerTime, hasFace: true, observation: sample(.neutral))
        flickering.startCapture()
        for index in 0...75 {
            flickerTime += 40
            flickering.observe(timestampMS: flickerTime, hasFace: true,
                               observation: sample(index % 5 == 1 ? .joy : .neutral))
        }
        expect(flickering.validation.isEmpty && flickering.completedSteps == 12,
               "80 percent frame agreement is insufficient without a continuous runtime-length hold")
        take(&teacher,label: .joy,time: &time) // Expected validation label is neutral.
        expect(teacher.validation.isEmpty && teacher.candidate == nil, "wrong expression cannot pass a repeat check")
        expect(teacher.examples == frozenExamples, "repeat checks never become training examples")
        for label in TaughtExpressionLabel.allCases { take(&teacher,label: label,time: &time) }
        expect(teacher.candidate != nil, "correct repetitions complete validation")
        teacher.retake(.disgust)
        expect(teacher.examples[.disgust] == nil && teacher.examples[.joy] != nil && teacher.validation.isEmpty && teacher.candidate == nil,
               "retake invalidates all old check results and preserves other teaching takes")
        teacher.retake(.neutral)
        expect(teacher.examples.isEmpty, "changing reference face requires a new full teaching run")

        var examples = profile.examples
        examples[.disgust] = examples[.joy]
        rejects("indistinguishable joy/disgust examples cannot be saved") { _ = try TaughtExpressionModel(examples: examples) }
        examples = profile.examples
        examples[.joy]![0].spread = [0.3,0.3,0.3,0.3,0.3]
        rejects("noisy expression cannot be accepted just by broadening its match radius") { _ = try TaughtExpressionModel(examples: examples) }
        examples = profile.examples
        examples[.joy]![1] = examples[.disgust]![1]
        rejects("inconsistent duplicate captures are rejected") { _ = try TaughtExpressionModel(examples: examples) }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TaughtExpressionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = directory.appendingPathComponent("local.json"), bundled = directory.appendingPathComponent("bundled.json")
        let store = TaughtExpressionStore(localURL: local, bundledURL: bundled)
        try store.save(profile)
        expect(store.load() == profile, "the entire frozen profile survives a fresh store instance")
        let data = try TaughtExpressionStore.encode(profile)
        let decoded = try TaughtExpressionStore.decode(data)
        expect(decoded == profile, "export/import is lossless")
        try data.write(to: bundled)
        var replacement = profile; replacement.id = UUID().uuidString
        try store.save(replacement)
        expect(store.load()?.id == replacement.id, "training build loads explicitly installed replacement")
        let demo = TaughtExpressionStore(localURL: local, bundledURL: bundled, allowLocal: false)
        expect(demo.load()?.id == profile.id, "demo build always uses bundled face, not leftover local training")
        rejects("locked demo profile cannot be overwritten") { try demo.save(replacement) }
        let before = try Data(contentsOf: local)
        var corrupt = replacement; corrupt.validation.removeValue(forKey: .anger)
        rejects("unverified profile cannot replace saved profile") { try store.save(corrupt) }
        let after = try Data(contentsOf: local)
        expect(after == before, "failed save leaves previous bytes intact")
        var installed = TaughtExpressionRuntime(profile: profile)
        rejects("failed persistence leaves active profile intact") { try installed.install(replacement,store: demo) }
        expect(installed.profile?.id == profile.id, "write failure cannot silently activate an unsaved profile")
        try installed.install(replacement,store: store)
        expect(installed.profile == replacement && store.load() == replacement, "explicit install saves and switches atomically")
        corrupt = profile; corrupt.schemaVersion = 99
        rejects("unknown profile schema rejected") { _ = try TaughtExpressionStore.decode(JSONEncoder().encode(corrupt)) }
        corrupt = profile; corrupt.measurementVersion = "other-model"
        rejects("incompatible feature units rejected") { _ = try corrupt.validatedModel() }
        corrupt = profile; corrupt.validation[.joy]!.accepted = 0
        rejects("failed repeat validation rejected") { _ = try corrupt.validatedModel() }
        corrupt = profile; corrupt.validation[.fear]!.longestHoldMS = 100
        rejects("export cannot claim validation without a usable hold") { _ = try corrupt.validatedModel() }
        rejects("oversized profile rejected") { _ = try TaughtExpressionStore.decode(Data(repeating: 0,count: 262_145)) }
        try Data("corrupt".utf8).write(to: local)
        expect(store.load() == profile, "corrupt local profile falls back to validated bundle")
        try Data("corrupt".utf8).write(to: bundled)
        expect(store.load() == nil, "two invalid profiles never enable default guesses")

        // Optional, explicitly synthetic fixture for disposable simulator/build validation.
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--fixture-output" {
            try TaughtExpressionStore.encode(profile).write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
        }
        print("PASS: \(checks) taught-expression checks (full-pattern matching, frozen profile, training/validation separation, lifecycle, persistence, demo lock)")
    }
}
