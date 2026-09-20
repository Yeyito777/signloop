import Foundation

@main
struct NoseScrunchTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1; if !condition() { fatalError("FAIL: \(message)") }
    }
    // Synthetic geometry exercises invariants; it does not establish camera accuracy.
    static func frame(_ label: TaughtExpressionLabel = .neutral, lift: Double? = nil,
                      lip: Float = 0.05, scale: Double = 1, angle: Double = 0,
                      width: Int = 720, height: Int = 1280, missing: Int? = nil) -> SkeletonFrame {
        let noseLift = lift ?? (label == .disgust ? 8 : 0)
        var points: [Int: (Double,Double)] = [
            33:(180,400), 133:(260,400), 362:(460,400), 263:(540,400), 1:(360,490),
            168:(360,408), 98:(326,490-noseLift), 327:(394,490-noseLift),
            105:(220,348), 107:(250,340), 70:(185,356),
            334:(500,348), 336:(470,340), 300:(535,356),
        ]
        let eye = label == .fear ? 0.16 : label == .joy ? 0.10 : 0.12
        for (up,down,x) in [(159,145,220.0),(158,153,235.0),(386,374,500.0),(385,380,485.0)] {
            points[up] = (x,400-eye*40); points[down] = (x,400+eye*40)
        }
        if label == .anger { for id in [105,107,70,334,336,300] { points[id]!.1 += 6 } }
        if label == .sadness { for id in [107,336] { points[id]!.1 -= 8 } }
        if let missing { points.removeValue(forKey: missing) }
        let landmarks = points.map { id, point in
            let x = (point.0-360)*scale, y = (point.1-400)*scale
            return SkeletonPoint(id: id, x: Float((360+x*cos(angle)-y*sin(angle))/Double(width)),
                                 y: Float((400+x*sin(angle)+y*cos(angle))/Double(height)), z: 0)
        }
        let smile: Float = label == .joy ? 0.65 : 0.05
        return SkeletonFrame(timestampMS: 0, width: width, height: height, camera: "front",
            hands: [], pose: [], face: landmarks, expressions: [
                "mouthSmileLeft":smile, "mouthSmileRight":smile,
                "mouthUpperUpLeft":lip, "mouthUpperUpRight":lip,
                "noseSneerLeft":0, "noseSneerRight":0,
            ], timingsMS: [:])
    }
    static func main() throws {
        let neutral = ExpressionObservation.from(frame())!
        let scrunch = ExpressionObservation.from(frame(.disgust))!
        expect(neutral.measurement == .noseScrunch, "new captures use nose geometry")
        expect(scrunch.values[.disgust]! > neutral.values[.disgust]!, "nose compression increases the scrunch measurement")
        let lipOnly = ExpressionObservation.from(frame(lip: 0.95))!
        expect(lipOnly.values == neutral.values, "upper-lip movement alone changes no new expression feature")
        for transformed in [frame(.disgust,scale: 0.7,angle: 0.3), frame(.disgust,width: 1280,height: 720)] {
            let value = ExpressionObservation.from(transformed)!
            expect(abs(value.values[.disgust]!-scrunch.values[.disgust]!) < 0.000001,
                   "scrunch survives scale, roll and image aspect changes")
        }
        for id in [98,168,327] {
            expect(ExpressionObservation.from(frame(missing: id)) == nil, "missing nose landmark \(id) abstains")
            expect(ExpressionObservation.from(frame(missing: id),measurement: .upperLip) != nil,
                   "legacy observations retain their original requirements")
        }
        var noCoefficients = frame(.disgust)
        noCoefficients = SkeletonFrame(timestampMS: 0, width: noCoefficients.width, height: noCoefficients.height,
            camera: "front", hands: [], pose: [], face: noCoefficients.face,
            expressions: ["mouthSmileLeft":0.05,"mouthSmileRight":0.05], timingsMS: [:])
        expect(ExpressionObservation.from(noCoefficients) != nil, "nose scrunch requires neither nose-sneer nor upper-lip coefficients")

        var teacher = ExpressionTeacher(), time = 0
        func take(_ label: TaughtExpressionLabel) {
            let observation = ExpressionObservation.from(frame(label,lip: label == .joy ? 0.9 : 0.05))!
            time += 100; teacher.observe(timestampMS: time,hasFace: true,observation: observation)
            teacher.startCapture()
            for _ in 0...30 { time += 100; teacher.observe(timestampMS: time,hasFace: true,observation: observation) }
        }
        for label in TaughtExpressionLabel.allCases { for _ in 0..<2 { take(label) } }
        expect(teacher.model != nil, "six landmark-based expressions create a model")
        for label in TaughtExpressionLabel.allCases { take(label) }
        expect(teacher.candidate != nil, "nose teaching completes the independent repeat checks")
        let profile = teacher.candidate!, model = try profile.validatedModel()
        expect(profile.measurement == .noseScrunch && profile.matchingVersion == 2, "profile stores nose units explicitly")
        for label in TaughtExpressionLabel.allCases {
            let observation = ExpressionObservation.from(frame(label,lip: 0.95))!
            expect(model.match(ExpressionCue.allCases.map { observation.values[$0]! }).label == label,
                   "\(label): lip raising cannot change the taught classification")
        }
        var runtime = TaughtExpressionRuntime(profile: profile)
        for timestamp in stride(from: 0,through: 400,by: 100) {
            runtime.observe(timestampMS: timestamp,hasFace: true,observation: scrunch)
        }
        expect(runtime.result == .active(.disgust), "stable nose scrunch activates disgust")
        runtime.observe(timestampMS: 500,hasFace: true,observation: lipOnly)
        expect(runtime.result == .neutral, "relaxing the nose releases disgust despite raised upper lip")

        var flat = profile.examples
        for index in 0..<2 { flat[.disgust]![index].center[4] = flat[.neutral]![index].center[4] }
        flat[.disgust]![0].center[2] = 0.08; flat[.disgust]![1].center[2] = 0.08
        do {
            _ = try TaughtExpressionModel(examples: flat)
            fatalError("FAIL: flat nose must not be accepted using eye narrowing instead")
        } catch {
            expect(error.localizedDescription.contains("nose scrunch"), "flat nose has an actionable retake message")
        }
        var legacyTeacher = ExpressionTeacher()
        legacyTeacher.observe(timestampMS: 0,hasFace: true,observation: ExpressionObservation.from(frame(),measurement: .upperLip))
        expect(!legacyTeacher.readyForCapture, "old lip observations cannot enter new teaching")
        let decoded = try TaughtExpressionStore.decode(TaughtExpressionStore.encode(profile))
        expect(decoded == profile, "nose profile survives export/import without losing its units")
        var wrongUnits = profile.validation[.disgust]!.example.center; wrongUnits[4] = 0.9
        expect(model.match(wrongUnits).label == nil, "positive lip values cannot pass a nose-profile repeat check")
        print("PASS: \(checks) nose-scrunch checks (landmark geometry, lip independence, real measurement pipeline, flat signal rejection, versioning)")
    }
}
