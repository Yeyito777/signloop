import Foundation

@main
struct GooseExpressionTests {
    static var checks = 0
    static func liveFrame(time: Int, smile: Float = 0.05, hasFace: Bool = true,
                          expressions: [String: Float]? = nil) -> SkeletonFrame {
        SkeletonFrame(timestampMS: time, width: 720, height: 1280, camera: "front",
            hands: [], pose: [], face: hasFace ? [SkeletonPoint(id: 1, x: 0.5, y: 0.4, z: 0)] : [],
            expressions: expressions ?? [
                "mouthSmileLeft": smile, "mouthSmileRight": smile, "browDownLeft": 0, "browDownRight": 0,
                "jawOpen": 0, "browInnerUp": 0.1, "noseSneerLeft": 0, "noseSneerRight": 0,
            ], timingsMS: [:])
    }
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1; guard value() else { fatalError("FAIL: \(message)") }
    }
    // Explicit synthetic test fixture only. Never bundled or installed on a phone.
    static func fixture() -> TaughtExpressionProfile {
        let vectors: [TaughtExpressionLabel: [Double]] = [
            .neutral: [0.05,-0.70,0.12,0.20,-0.24], .joy: [0.65,-0.72,0.10,0.21,-0.20],
            .anger: [0.08,-0.50,0.10,0.15,-0.24], .fear: [0.07,-0.78,0.30,0.20,-0.24],
            .sadness: [0.05,-0.78,0.11,0.38,-0.24], .disgust: [0.08,-0.64,0.09,0.16,-0.20]]
        var examples: [TaughtExpressionLabel: [ExpressionExample]] = [:]
        var validation: [TaughtExpressionLabel: ExpressionValidation] = [:]
        for label in TaughtExpressionLabel.allCases {
            let example = ExpressionExample(center: vectors[label]!, spread: Array(repeating: 0.001, count: 5),
                sampleCount: 20, jawOpening: label == .fear ? 0.8 : 0.2, jawSpread: 0.001)
            examples[label] = [example, example]
            validation[label] = ExpressionValidation(example: example, accepted: 20, total: 20, longestHoldMS: 1000)
        }
        return TaughtExpressionProfile(id: UUID().uuidString, createdAt: Date(), camera: "front",
            pose: ExpressionPose(horizontal: 0, vertical: 0.25), examples: examples, validation: validation)
    }
    static func main() throws {
        let joy = GooseExpressionSnapshot(status: .active, emotion: .joy)
        let anger = GooseExpressionSnapshot(status: .active, emotion: .anger)
        let neutral = GooseExpressionSnapshot(status: .neutral)
        var history = GooseExpressionHistory()
        for time in stride(from: 0, through: 1000, by: 100) { history.append(joy, at: time) }
        for time in stride(from: 1100, through: 1600, by: 100) { history.append(anger, at: time) }
        expect(history.emotion(from: 100, through: 1000) == .joy, "delayed worker uses its input interval, not the latest face")
        expect(history.emotion(from: 1200, through: 1600) == .anger, "next gesture has its own expression")
        expect(history.emotion(from: 1600, through: 1600) == .anger, "single-frame preview uses its matching frame")
        expect(history.emotion(from: 2100, through: 2200) == .neutral, "old samples cannot annotate a new sign")
        history.reset()
        for time in stride(from: 0, through: 1000, by: 100) { history.append(time < 800 ? joy : neutral, at: time) }
        expect(history.emotion(from: 0, through: 1000) == .joy, "brief relaxation at sign completion preserves its dominant expression")
        expect(history.emotion(from: 800, through: 1000) == .neutral, "an expression outside the sign interval cannot leak in")
        history.reset()
        let holdingJoy = GooseExpressionSnapshot(status: .holding, emotion: .joy)
        for time in stride(from: 0, through: 1000, by: 100) { history.append(time < 400 ? holdingJoy : joy, at: time) }
        expect(history.emotion(from: 0, through: 1000) == .joy, "holding the taught face still counts toward the sign")
        history.reset()
        for time in stride(from: 0, through: 1000, by: 100) { history.append(time < 500 ? joy : anger, at: time) }
        expect(history.emotion(from: 0, through: 1000) == .neutral, "tied expressions abstain")
        history.append(anger, at: 2000)
        expect(history.emotion(from: 0, through: 1000) == .neutral, "tracking discontinuity discards old expression history")
        history.append(joy, at: 1900)
        expect(history.emotion(from: 2000, through: 2000) == .joy, "clock reversal resets earlier samples")
        history.reset()
        expect(history.emotion(from: 0, through: 0) == .neutral, "capture reset clears all facial evidence")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = directory.appendingPathComponent("local.json"), bundle = directory.appendingPathComponent("bundle.json")
        expect(GooseExpressionProfile.load(localURL: local, bundledURL: nil).failure == .noProfile, "missing profile is explicit")
        let profile = fixture()
        try TaughtExpressionStore.encode(profile).write(to: bundle)
        let bundled = GooseExpressionProfile.load(localURL: local, bundledURL: bundle)
        expect(bundled.profile?.id == profile.id && bundled.failure == nil, "valid bundle loads through real schema validation")
        try Data("{}".utf8).write(to: local)
        expect(GooseExpressionProfile.load(localURL: local, bundledURL: bundle).failure == .profileInvalid, "invalid local replacement is diagnosed")
        var replacement = fixture(); replacement.id = UUID().uuidString
        try TaughtExpressionStore.encode(replacement).write(to: local)
        expect(GooseExpressionProfile.load(localURL: local, bundledURL: bundle).profile?.id == replacement.id,
            "checked local profile overrides bundle without retraining")
        let taught = directory.appendingPathComponent("taught.json")
        try TaughtExpressionStore.encode(profile).write(to: taught)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: local.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: taught.path)
        expect(GooseExpressionProfile.load(localURL: local, taughtURL: taught, bundledURL: bundle).profile?.id == profile.id,
            "a newer checked profile saved by Expo Expression lab is used")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 300)], ofItemAtPath: local.path)
        expect(GooseExpressionProfile.load(localURL: local, taughtURL: taught, bundledURL: bundle).profile?.id == replacement.id,
            "a newer provisioned profile replaces an older lab profile")
        try Data("{}".utf8).write(to: taught)
        expect(GooseExpressionProfile.load(localURL: local, taughtURL: taught, bundledURL: bundle).failure == .profileInvalid,
            "an invalid newest local profile cannot silently fall back")
        var tracker = GooseExpressionTracker(source: bundled, modelAvailable: false)
        expect(tracker.snapshot.status == .modelMissing && tracker.snapshot.emotion == .neutral, "missing face model stays neutral")
        tracker.reset()
        expect(tracker.snapshot.status == .modelMissing, "reset preserves setup diagnostics")
        var live = GooseExpressionTracker(source: GooseExpressionProfile.load(
            localURL: directory.appendingPathComponent("missing.json"), bundledURL: nil), modelAvailable: true)
        expect(live.snapshot.status == .noFace && live.snapshot.emotion == .neutral,
            "conversation face tracking runs without Expression lab")
        expect(!live.title.contains("profile"), "missing taught profile does not block live mood")
        for time in stride(from: 0, through: 400, by: 40) { live.observe(Self.liveFrame(time: time, smile: 0.05)) }
        expect(live.snapshot.status == .neutral && live.snapshot.emotion == .neutral, "a rest face stays Neutral")
        live.observe(Self.liveFrame(time: 440, smile: 0.55))
        expect(live.snapshot.status == .holding && live.snapshot.emotion == .joy, "a smile is Joy without a 2s rest-face capture")
        live.observe(Self.liveFrame(time: 540, smile: 0.55))
        expect(live.snapshot.status == .active && live.snapshot.emotion == .joy, "holding the smile becomes a live match")
        live.observe(Self.liveFrame(time: 700, smile: 0.04))
        expect(live.snapshot.status == .neutral, "relaxing the mouth returns to Neutral")
        live.observe(Self.liveFrame(time: 800, smile: 0.55, hasFace: false))
        expect(live.snapshot.status == .noFace, "looking away is no-face, not Neutral")
        var empty = GooseExpressionTracker(source: GooseExpressionProfile.load(
            localURL: directory.appendingPathComponent("missing.json"), bundledURL: nil), modelAvailable: true)
        empty.observe(Self.liveFrame(time: 0, expressions: [:]))
        expect(empty.snapshot.status == .unavailable, "landmarks without blendshapes cannot fake a mood")
        print("PASS: \(checks) goose expression integration checks")
    }
}
