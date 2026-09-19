import Foundation

@main
struct ExpressionCueTests {
    static var checks = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard value() else { fatalError("FAIL: \(message)") }
    }
    // Synthetic geometry tests behavior, not real-camera recognition accuracy.
    // Neutral has small eyes and already-raised inner brows, like the reported case.
    static func frame(eye: Double = 0.12, browDrop: Double = 0, innerLift: Double = 0,
                      smile: Float = 0.05, lip: Float = 0.05,
                      scale: Double = 1, angle: Double = 0, width: Int = 720,
                      height: Int = 1280) -> SkeletonFrame {
        var coordinates: [Int: (Double, Double)] = [
            33:(180,400), 133:(260,400), 362:(460,400), 263:(540,400), 1:(360,490),
            105:(220,348), 107:(250,340), 70:(185,356),
            334:(500,348), 336:(470,340), 300:(535,356),
        ]
        for (up, down, x) in [(159,145,220.0), (158,153,235.0), (386,374,500.0), (385,380,485.0)] {
            coordinates[up] = (x,400-eye*40)
            coordinates[down] = (x,400+eye*40)
        }
        for id in [105,107,70,334,336,300] { coordinates[id]!.1 += browDrop }
        for id in [107,336] { coordinates[id]!.1 -= innerLift }
        let points = coordinates.map { id, pair in
            let x = (pair.0-360)*scale, y = (pair.1-400)*scale
            return SkeletonPoint(id: id,
                x: Float((360+x*cos(angle)-y*sin(angle))/Double(width)),
                y: Float((400+x*sin(angle)+y*cos(angle))/Double(height)), z: 0)
        }
        return SkeletonFrame(timestampMS: 0, width: width, height: height, camera: "front",
            hands: [], pose: [], face: points, expressions: [
                "mouthSmileLeft":smile, "mouthSmileRight":smile,
                "mouthUpperUpLeft":lip, "mouthUpperUpRight":lip,
                // These detector channels may be flat or biased. No dependency remains.
                "eyeWideLeft":0, "eyeWideRight":0, "browDownLeft":0, "browDownRight":0,
                "browInnerUp":0.9, "noseSneerLeft":0, "noseSneerRight":0,
            ], timingsMS: [:])
    }
    static func reading(_ cue: ExpressionCue? = nil) -> ExpressionObservation {
        let value: SkeletonFrame
        switch cue {
        case .joy: value = frame(eye: 0.09, smile: 0.5, lip: 0.6)
        case .anger: value = frame(browDrop: 6)
        case .fear: value = frame(eye: 0.135)
        case .sadness: value = frame(innerLift: 4)
        case .disgust: value = frame(eye: 0.09, lip: 0.4)
        case nil: value = frame()
        }
        return ExpressionObservation.from(value)!
    }
    static func replacing(_ source: SkeletonFrame, face: [SkeletonPoint]? = nil,
                          expressions: [String: Float]? = nil) -> SkeletonFrame {
        SkeletonFrame(timestampMS: source.timestampMS, width: source.width, height: source.height,
                      camera: source.camera, hands: source.hands, pose: source.pose,
                      face: face ?? source.face, expressions: expressions ?? source.expressions,
                      timingsMS: source.timingsMS)
    }
    static func feed(_ engine: inout ExpressionCueEngine, _ observation: ExpressionObservation,
                     from start: Int, through end: Int) {
        for time in stride(from: start, through: end, by: 100) {
            engine.observe(timestampMS: time, hasFace: true, observation: observation)
        }
    }
    static func calibrated() -> ExpressionCueEngine {
        var engine = ExpressionCueEngine()
        engine.observe(timestampMS: 0, hasFace: true, observation: reading())
        engine.startCalibration(.baseline)
        feed(&engine, reading(), from: 100, through: 2100)
        expect(engine.hasBaseline && engine.profile.isValid, "personal baseline is valid")
        engine.resetTracking()
        return engine
    }
    static func main() throws {
        let neutral = reading()
        expect(abs(neutral.values[.fear]! - 0.12) < 0.00001, "eye gap uses actual aspect-correct geometry")
        expect(neutral.values[.anger]! < -0.6, "raised neutral brows are a measurable personal position")
        expect(neutral.values[.sadness]! > 0.19, "raised inner brows exist at neutral")
        for transformed in [frame(scale: 0.7, angle: 0.3), frame(width: 1280, height: 720)] {
            let measured = ExpressionObservation.from(transformed)!
            for cue in ExpressionCue.allCases {
                expect(abs(measured.values[cue]! - neutral.values[cue]!) < 0.00001,
                       "\(cue) geometry survives scale, roll and image aspect changes")
            }
            expect(measured.pose.isNear(neutral.pose), "pose guard is roll/scale invariant")
        }
        let missing = replacing(frame(), face: frame().face.filter { $0.id != 158 })
        expect(ExpressionObservation.from(missing) == nil, "missing landmark is unavailable, never zero")
        let duplicate = replacing(frame(), face: frame().face + [frame().face[0]])
        expect(ExpressionObservation.from(duplicate) == nil, "duplicate IDs cannot silently change geometry")
        var invalidSignals = frame().expressions
        invalidSignals["mouthSmileLeft"] = .nan
        var invalid = replacing(frame(), expressions: invalidSignals)
        expect(ExpressionObservation.from(invalid) == nil, "nonfinite coefficients rejected")
        invalidSignals.removeValue(forKey: "mouthSmileLeft")
        invalid = replacing(frame(), expressions: invalidSignals)
        expect(ExpressionObservation.from(invalid) == nil, "both mouth sides are required")
        expect(ExpressionObservation.from(frame(width: 0)) == nil, "invalid image dimensions rejected")

        var fresh = ExpressionCueEngine()
        fresh.startCalibration(.baseline)
        expect(fresh.calibration == nil, "cannot calibrate without face")
        for cue in ExpressionCue.allCases {
            expect(fresh.threshold(for: cue) == 0.15, "\(cue) defaults to the most sensitive setting")
            feed(&fresh, reading(cue), from: 0, through: 600)
            expect(fresh.decision == .needsBaseline, "no average-face classification before personal setup")
            fresh.resetTracking()
        }
        fresh.observe(timestampMS: 0, hasFace: true, observation: neutral)
        fresh.startCalibration(.cue(.joy))
        expect(fresh.calibration == nil, "cue capture requires personal baseline")

        for cue in ExpressionCue.allCases {
            var engine = calibrated()
            feed(&engine, neutral, from: 0, through: 600)
            expect(engine.decision == .none, "\(cue): raised neutral brows and small eyes select no preset")
            engine.resetTracking()
            engine.observe(timestampMS: 0, hasFace: true, observation: reading(cue))
            expect(engine.decision == .holding(cue), "\(cue): isolated cue starts a fresh hold")
            feed(&engine, reading(cue), from: 100, through: 200)
            expect(engine.decision == .holding(cue), "\(cue): no early activation")
            feed(&engine, reading(cue), from: 300, through: 600)
            expect(engine.decision == .active(cue), "\(cue): deliberate movement activates without ambiguity")
            feed(&engine, neutral, from: 700, through: 1700)
            expect(engine.decision == .none, "\(cue): relaxing clears the preset")
            engine.startCalibration(.cue(cue))
            feed(&engine, reading(cue), from: 1800, through: 3800)
            expect(engine.peaks[cue] != nil && engine.profile.isValid, "\(cue): comfortable range can be saved")
            expect(engine.decision == .none, "capture never emits a preset")
            let previous = engine.peaks[cue]
            engine.startCalibration(.cue(cue))
            feed(&engine, neutral, from: 3900, through: 5900)
            expect(engine.peaks[cue] == previous, "\(cue): flat response cannot overwrite a good range")
        }
        var engine = calibrated()
        feed(&engine, reading(.joy), from: 0, through: 800)
        expect(engine.decision == .active(.joy) && engine.levels[.disgust] == 0,
               "smile + upper lip lift + narrowed eyes is joy, never joy/disgust ambiguity")
        engine.resetTracking()
        let lipOnly = ExpressionObservation.from(frame(lip: 0.8))!
        feed(&engine, lipOnly, from: 0, through: 800)
        expect(engine.decision == .none, "upper lip lift alone no longer means disgust")
        engine.startCalibration(.cue(.disgust))
        feed(&engine, reading(.joy), from: 900, through: 2900)
        expect(engine.peaks[.disgust] == nil, "a smile cannot be calibrated as disgust")
        engine.resetTracking()
        let shut = ExpressionObservation.from(frame(eye: 0.015, lip: 0.8))!
        feed(&engine, shut, from: 0, through: 800)
        expect(engine.decision == .none, "closed eyes plus lip movement do not become disgust")
        engine.resetTracking()
        feed(&engine, reading(.disgust), from: 0, through: 800)
        engine.observe(timestampMS: 900, hasFace: true, observation: reading(.joy))
        expect(engine.decision != .active(.disgust) && engine.levels[.disgust] == 0,
               "a smile immediately releases active disgust without a smoothed conflict")
        engine.resetTracking()
        var mixed = reading(.anger)
        mixed.values[.fear] = reading(.fear).values[.fear]
        feed(&engine, mixed, from: 0, through: 800)
        expect(engine.decision == .ambiguous([.anger,.fear]), "genuinely separate conflicting cues still abstain")
        engine.resetTracking()
        var incidental = reading(.joy)
        incidental.values[.sadness]! += 0.028 // Level 0.20, versus a strong smile.
        feed(&engine, incidental, from: 0, through: 800)
        expect(engine.decision == .active(.joy), "weak secondary brow movement does not cancel a clear smile")
        engine.resetTracking()
        incidental.values[.sadness]! += 0.10
        feed(&engine, incidental, from: 0, through: 800)
        expect(engine.decision == .ambiguous([.joy,.sadness]), "two strong cues remain ambiguous")

        // A blink in the baseline should not enlarge the eye-wide noise bound.
        var blinking = ExpressionCueEngine()
        blinking.observe(timestampMS: 0, hasFace: true, observation: neutral)
        blinking.startCalibration(.baseline)
        for sample in 0...20 {
            blinking.observe(timestampMS: 100+sample*100, hasFace: true,
                             observation: (8...10).contains(sample) ? ExpressionObservation.from(frame(eye: 0.015))! : neutral)
        }
        expect(blinking.hasBaseline, "naturally blinking during relaxed capture is accepted")
        feed(&blinking, reading(.fear), from: 2200, through: 3000)
        expect(blinking.decision == .active(.fear), "small-eye widening still works after a blink in calibration")

        // Sustained, all-cue resting variation at minimum sensitivity must stay neutral.
        var noisy = ExpressionCueEngine()
        noisy.observe(timestampMS: 0, hasFace: true, observation: neutral)
        noisy.startCalibration(.baseline)
        var upperRest = neutral
        for cue in ExpressionCue.allCases { upperRest.values[cue]! += cue.noiseFloor * 1.5 }
        for sample in 0...20 {
            noisy.observe(timestampMS: 100+sample*100, hasFace: true,
                          observation: sample.isMultiple(of: 2) ? neutral : upperRest)
        }
        for sample in 0...40 {
            noisy.observe(timestampMS: 2200+sample*100, hasFace: true,
                          observation: (sample/8).isMultiple(of: 2) ? neutral : upperRest)
            expect(noisy.decision == .none, "resting variation cannot make everything ambiguous")
        }
        let savedNoise = noisy.profile
        noisy.resetTracking()
        expect(noisy.profile == savedNoise, "resting noise guards survive pauses")

        engine = calibrated()
        engine.observe(timestampMS: 0, hasFace: true, observation: reading(.fear))
        for _ in 0..<20 { engine.observe(timestampMS: 0, hasFace: true, observation: reading(.fear)) }
        expect(engine.decision == .holding(.fear), "duplicates never advance hold time")
        engine.observe(timestampMS: 1000, hasFace: true, observation: reading(.fear))
        expect(engine.decision == .holding(.fear), "long gap restarts the hold")
        engine.observe(timestampMS: 900, hasFace: true, observation: reading(.fear))
        expect(engine.decision == .unavailable, "backward timestamp invalidates tracking")
        feed(&engine, reading(.fear), from: 1100, through: 1800)
        engine.observe(timestampMS: 1900, hasFace: false, observation: nil)
        expect(engine.decision == .noFace && engine.raw.isEmpty && engine.levels.isEmpty, "face loss clears results")
        engine.observe(timestampMS: 2000, hasFace: true, observation: reading(.fear))
        expect(engine.decision == .holding(.fear), "re-entry starts a new hold")
        engine.observe(timestampMS: 2100, hasFace: true, observation: nil)
        expect(engine.decision == .unavailable && !engine.hasCompleteFace, "missing geometry abstains")
        var bad = neutral
        bad.values[.fear] = .infinity
        engine.observe(timestampMS: 2200, hasFace: true, observation: bad)
        expect(engine.decision == .unavailable, "engine also rejects invalid measurements")
        engine.resetTracking()
        var turn = reading(.fear)
        turn.pose.horizontal += 0.2
        feed(&engine, turn, from: 0, through: 800)
        expect(engine.decision == .faceForward && engine.levels.isEmpty, "view angle change abstains")
        feed(&engine, reading(.fear), from: 900, through: 1600)
        expect(engine.decision == .active(.fear), "returning to original angle restores classification")
        var rear = reading(.fear)
        rear.camera = "back"
        feed(&engine, rear, from: 1700, through: 2300)
        expect(engine.decision == .needsBaseline && !engine.canUseBaseline, "different camera needs its own neutral")
        engine.startCalibration(.cue(.fear))
        expect(engine.calibration == nil, "wrong camera cannot calibrate a cue against old neutral")

        engine = calibrated()
        engine.setThreshold(0.7, for: .fear)
        engine.setThreshold(.nan, for: .fear)
        expect(engine.threshold(for: .fear) == 0.7, "invalid threshold ignored")
        feed(&engine, reading(.fear), from: 0, through: 800)
        expect(engine.decision == .none, "raising threshold makes small eye change insufficient")
        engine.setThreshold(-1, for: .fear)
        expect(engine.threshold(for: .fear) == 0.15, "threshold clamps to sensitive bound")
        feed(&engine, reading(.fear), from: 900, through: 1700)
        expect(engine.decision == .active(.fear), "minimum threshold restores gentle-eye activation")
        engine.resetTracking()
        var borderline = neutral
        borderline.values[.joy]! += 0.015 + 0.4 * 0.13
        feed(&engine, borderline, from: 0, through: 800)
        expect(engine.decision == .none, "release margin cannot activate a new cue")
        feed(&engine, reading(.joy), from: 900, through: 1700)
        feed(&engine, borderline, from: 1800, through: 2800)
        expect(engine.decision == .active(.joy), "hysteresis holds until below release threshold")
        feed(&engine, neutral, from: 2900, through: 3900)
        expect(engine.decision == .none, "neutral releases the hysteresis hold")

        engine = calibrated()
        engine.observe(timestampMS: 0, hasFace: true, observation: neutral)
        let previous = engine.profile
        engine.startCalibration(.baseline)
        feed(&engine, neutral, from: 100, through: 500)
        engine.observe(timestampMS: 600, hasFace: false, observation: nil)
        expect(engine.calibration == nil && engine.profile == previous, "interrupted capture preserves saved profile")
        engine.observe(timestampMS: 700, hasFace: true, observation: neutral)
        engine.startCalibration(.baseline)
        engine.cancelCalibration()
        expect(engine.profile == previous, "cancel keeps completed calibration")
        engine.startCalibration(.baseline)
        engine.observe(timestampMS: 800, hasFace: true, observation: neutral)
        engine.observe(timestampMS: 1800, hasFace: true, observation: neutral)
        expect(engine.calibration == nil && engine.profile == previous, "frame gap aborts calibration")
        engine.startCalibration(.baseline)
        for sample in 0...20 {
            var motion = neutral
            if sample.isMultiple(of: 2) { motion.pose.horizontal += 0.15 }
            engine.observe(timestampMS: 1900+sample*100, hasFace: true, observation: motion)
        }
        expect(engine.profile == previous && engine.calibrationMessage.contains("head still"), "moving baseline rejected")
        engine.startCalibration(.baseline)
        for sample in 0...20 {
            engine.observe(timestampMS: 4000+sample*100, hasFace: true,
                           observation: sample.isMultiple(of: 2) ? neutral : reading(.joy))
        }
        expect(engine.profile == previous && engine.calibrationMessage.contains("expression changed"),
               "unstable neutral capture cannot silently create an unusably large dead zone")

        // Complete numeric profile roundtrip; corrupted/older/incomplete profiles fail closed.
        let suite = "Signloop.ExpressionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        engine = calibrated()
        engine.observe(timestampMS: 0, hasFace: true, observation: neutral)
        engine.startCalibration(.cue(.joy))
        feed(&engine, reading(.joy), from: 100, through: 2100)
        engine.setThreshold(0.25, for: .sadness)
        ExpressionProfileStore.save(engine.profile, to: defaults)
        let loaded = ExpressionProfileStore.load(from: defaults)
        expect(loaded == engine.profile, "neutral, noise, camera, ranges and sliders all roundtrip")
        var restored = ExpressionCueEngine(profile: loaded)
        feed(&restored, neutral, from: 0, through: 800)
        expect(restored.decision == .none, "saved own-face baseline stays neutral after restart")
        feed(&restored, reading(.anger), from: 900, through: 1700)
        expect(restored.decision == .active(.anger), "furrow is relative to restored raised brows")
        var corrupted = loaded
        corrupted.version = 99
        defaults.set(try JSONEncoder().encode(corrupted), forKey: ExpressionProfileStore.key)
        expect(!ExpressionProfileStore.load(from: defaults).hasBaseline, "unknown feature schema rejected")
        corrupted = loaded
        corrupted.noise.removeValue(forKey: .fear)
        expect(!ExpressionCueEngine(profile: corrupted).hasBaseline, "partial profile rejected")
        corrupted = loaded
        corrupted.thresholds[.fear] = -1
        expect(!corrupted.isValid, "invalid persisted threshold rejected")
        defaults.set(Data("broken".utf8), forKey: ExpressionProfileStore.key)
        expect(!ExpressionProfileStore.load(from: defaults).hasBaseline, "corrupt storage fails safely")
        ExpressionProfileStore.save(loaded, to: defaults)
        restored.resetCalibration()
        ExpressionProfileStore.save(restored.profile, to: defaults)
        expect(defaults.object(forKey: ExpressionProfileStore.key) == nil, "forget face actually deletes stored data")
        expect(!restored.hasBaseline && restored.thresholds.isEmpty, "reset restores most-sensitive defaults")
        print("PASS: \(checks) expression checks (personal neutral, geometry, smile/scrunch separation, noise, lifecycle, persistence)")
    }
}
