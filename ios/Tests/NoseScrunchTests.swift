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
                      width: Int = 720, height: Int = 1280, missing: Int? = nil,
                      gap: Double? = nil, jaw: Float? = nil, smile: Float? = nil,
                      eyeOpening: Double? = nil) -> SkeletonFrame {
        let noseLift = lift ?? (label == .disgust ? 8 : 0)
        var points: [Int: (Double,Double)] = [
            33:(180,400), 133:(260,400), 362:(460,400), 263:(540,400), 1:(360,490),
            168:(360,408), 98:(326,490-noseLift), 327:(394,490-noseLift),
            105:(220,348), 107:(250,340), 70:(185,356),
            334:(500,348), 336:(470,340), 300:(535,356),
            13:(360,530), 14:(360,530+(gap ?? (label == .fear ? 54 : 1))),
        ]
        let eye = eyeOpening ?? (label == .joy ? 0.10 : 0.12)
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
        let smile = smile ?? (label == .joy ? 0.65 : 0.05)
        return SkeletonFrame(timestampMS: 0, width: width, height: height, camera: "front",
            hands: [], pose: [], face: landmarks, expressions: [
                "mouthSmileLeft":smile, "mouthSmileRight":smile,
                "mouthUpperUpLeft":lip, "mouthUpperUpRight":lip,
                "noseSneerLeft":0, "noseSneerRight":0,
                "jawOpen":jaw ?? (label == .fear ? 0.6 : 0.01),
            ], timingsMS: [:])
    }
    static func main() throws {
        let neutral = ExpressionObservation.from(frame())!
        let scrunch = ExpressionObservation.from(frame(.disgust))!
        expect(neutral.measurement == .jawDrop, "new captures use jaw and nose measurements")
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
            expressions: ["mouthSmileLeft":0.05,"mouthSmileRight":0.05,"jawOpen":0.01], timingsMS: [:])
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
        expect(profile.measurement == .jawDrop && profile.matchingVersion == 2, "profile stores jaw/nose units explicitly")
        for label in TaughtExpressionLabel.allCases {
            let observation = ExpressionObservation.from(frame(label,lip: 0.95))!
            expect(model.match(ExpressionCue.allCases.map { observation.values[$0]! }, jawOpening: observation.jawOpening).label == label,
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
        expect(model.match(wrongUnits, jawOpening: 0.01).label == nil, "positive lip values cannot pass a nose-profile repeat check")
        try jawDropChecks(profile)
        print("PASS: \(checks) face-movement checks (nose geometry, jaw drop, open-mouth smiles, measurement pipeline, versioning)")
    }

    static func jawDropChecks(_ profile: TaughtExpressionProfile) throws {
        let model = try profile.validatedModel()
        func reading(_ frame: SkeletonFrame) -> ExpressionObservation { ExpressionObservation.from(frame)! }
        func match(_ frame: SkeletonFrame) -> TaughtExpressionLabel? {
            let observation = reading(frame)
            return model.match(ExpressionCue.allCases.map { observation.values[$0]! }, jawOpening: observation.jawOpening).label
        }
        expect(match(frame(.fear)) == .fear, "jaw drop works with naturally relaxed eyes")
        expect(match(frame(eyeOpening: 0.30)) == .neutral, "eye widening alone cannot trigger fear")
        expect(match(frame(gap: 54,jaw: 0.01)) == .neutral, "parted lips without a dropped jaw do not trigger fear")
        expect(match(frame(gap: 0,jaw: 0.8)) == .neutral, "jaw score without visible mouth opening does not trigger fear")
        expect(match(frame(gap: 6,jaw: 0.8)) != .fear, "small lip separation is insufficient for a jaw-drop preset")
        for gap in [0.0, 30, 54, 90] {
            expect(match(frame(.joy,gap: gap,jaw: 0.8)) == .joy,
                   "taught smile stays joy with \(gap) pixels of mouth opening")
        }
        for smile: Float in [0.18, 0.3, 0.65, 0.9] {
            expect(match(frame(.fear,smile: smile)) != .fear, "detected smile \(smile) vetoes fear even on a fear-like face")
        }
        let full = reading(frame(.fear)).values[.fear]!
        for transformed in [frame(.fear,scale: 0.7,angle: 0.3),frame(.fear,width: 1280,height: 720)] {
            expect(abs(reading(transformed).values[.fear]!-full) < 0.000001,
                   "jaw opening survives scale, roll and aspect changes")
        }
        for id in [13,14] {
            expect(ExpressionObservation.from(frame(.fear,missing: id)) == nil, "missing mouth landmark abstains")
            expect(ExpressionObservation.from(frame(.fear,missing: id),measurement: .noseScrunch) != nil,
                   "saved eye/nose profiles keep their original landmark requirements")
        }
        var coefficients = frame(.fear).expressions
        for value in [Float.nan, -0.1, 1.1] {
            coefficients["jawOpen"] = value
            let source = frame(.fear)
            let invalid = SkeletonFrame(timestampMS: 0,width: source.width,height: source.height,camera: "front",
                hands: [],pose: [],face: source.face,expressions: coefficients,timingsMS: [:])
            expect(ExpressionObservation.from(invalid) == nil, "invalid jaw coefficient cannot substitute for a jaw drop")
        }
        coefficients.removeValue(forKey: "jawOpen")
        let source = frame(.fear)
        let missing = SkeletonFrame(timestampMS: 0,width: source.width,height: source.height,camera: "front",
            hands: [],pose: [],face: source.face,expressions: coefficients,timingsMS: [:])
        expect(ExpressionObservation.from(missing) == nil, "missing jaw channel abstains")

        var examples = profile.examples
        for index in 0..<2 { examples[.fear]![index].center[0] = 0.4 }
        do { _ = try TaughtExpressionModel(examples: examples); fatalError("FAIL: smiling fear capture must be rejected") }
        catch { expect(error.localizedDescription.contains("smile"), "teaching explains how to separate fear from a smile") }
        examples = profile.examples
        for index in 0..<2 { examples[.fear]![index].center[2] = examples[.neutral]![index].center[2]+0.01 }
        do { _ = try TaughtExpressionModel(examples: examples); fatalError("FAIL: tiny lip parting cannot teach fear") }
        catch { expect(error.localizedDescription.contains("jaw drop"), "teaching requires visible jaw movement") }
        examples = profile.examples
        for index in 0..<2 { examples[.fear]![index].jawOpening = examples[.neutral]![index].jawOpening }
        do { _ = try TaughtExpressionModel(examples: examples); fatalError("FAIL: a flat raw jaw signal cannot teach fear") }
        catch { expect(error.localizedDescription.contains("jaw signal"), "teaching requires raw jaw motion as well as lip opening") }
        examples = profile.examples
        for label in TaughtExpressionLabel.allCases {
            for index in 0..<2 { examples[label]![index].jawOpening = label == .fear ? 0.8 : 0.35 }
        }
        let biased = try TaughtExpressionModel(examples: examples)
        let opened = reading(frame(.fear,jaw: 0.35))
        let vector = ExpressionCue.allCases.map { opened.values[$0]! }
        expect(biased.match(vector,jawOpening: 0.35).label != .fear,
               "lip opening with an unchanged biased jaw reading cannot trigger fear")
        expect(biased.match(vector,jawOpening: 0.8).label == .fear,
               "actual jaw movement beyond a biased baseline still activates fear")
        expect(biased.match(vector).label == nil, "new profile matching never assumes a missing jaw reading")
        var runtime = TaughtExpressionRuntime(profile: profile)
        for time in stride(from: 0,through: 400,by: 100) {
            runtime.observe(timestampMS: time,hasFace: true,observation: reading(frame(.fear)))
        }
        expect(runtime.result == .active(.fear), "stable jaw drop activates fear")
        runtime.observe(timestampMS: 500,hasFace: true,observation: reading(frame(.joy,gap: 54,jaw: 0.8)))
        expect(runtime.result == .holding(.joy), "smile immediately cancels active fear before the joy hold completes")
        for time in stride(from: 600,through: 900,by: 100) {
            runtime.observe(timestampMS: time,hasFace: true,observation: reading(frame(.joy,gap: 54,jaw: 0.8)))
        }
        expect(runtime.result == .active(.joy), "open-mouth smile settles on joy, never fear")
        runtime.observe(timestampMS: 1000,hasFace: true,observation: ExpressionObservation.from(frame(.fear),measurement: .noseScrunch))
        expect(runtime.result == .unavailable, "saved eye measurements cannot be read as jaw measurements")
    }
}
