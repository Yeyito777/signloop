import Foundation

@main struct SegmentedSignTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); checks += 1
        }
        // Synthetic movements exercise boundaries and scheduling, not ASL accuracy.
        func frame(_ t: Int, x: Float = 0.5, fingers: Float = 0, hands: Bool = true, body: Bool = true) -> SkeletonFrame {
            let points = (0..<21).map { i in
                SkeletonPoint(id: i, x: x + Float(i % 5)*0.015 + (i > 4 ? fingers : 0),
                    y: 0.35 - Float(i)*0.004, z: 0)
            }
            let pose = [SkeletonPoint(id: 11, x: 0.4, y: 0.4, z: 0),
                        SkeletonPoint(id: 12, x: 0.6, y: 0.4, z: 0),
                        SkeletonPoint(id: 13, x: 0.4, y: 0.5, z: 0),
                        SkeletonPoint(id: 14, x: 0.6, y: 0.5, z: 0),
                        SkeletonPoint(id: 15, x: x, y: 0.35, z: 0),
                        SkeletonPoint(id: 16, x: 0.65, y: 0.6, z: 0)]
            return SkeletonFrame(timestampMS: t, width: 720, height: 1280, camera: "synthetic",
                hands: hands ? [SkeletonHand(points: points, modelHandedness: "Right", handednessScore: 1, poseSide: "Left")] : [],
                pose: body ? pose : [], face: [], expressions: [:], timingsMS: [:])
        }
        for step in [33, 67] {
            var segmenter = BasicSignSegmentation()
            var segments: [[SkeletonFrame]] = []
            for t in stride(from: 0, through: 2600, by: step) {
                if let complete = segmenter.update(frame(t)) { segments.append(complete) }
            }
            check(segments.count == 1, "One held sign produces one segment at 15/30 FPS")
            check(segments[0].last!.timestampMS - segments[0][0].timestampMS >= 400, "Static completion has enough temporal evidence")
            check(segments[0].allSatisfy(\.hasSigningPose), "Body geometry survives segmentation")
        }
        var articulating = BasicSignSegmentation()
        var articulated: [[SkeletonFrame]] = []
        for t in stride(from: 0, through: 2000, by: 50) {
            let offset: Float = (350...1050).contains(t) ? (t / 50 % 2 == 0 ? 0.04 : -0.04) : 0
            if let complete = articulating.update(frame(t, fingers: offset)) { articulated.append(complete) }
        }
        check(articulated.count == 1, "Finger articulation with a fixed wrist produces a completed gesture")
        check(articulated[0].contains { abs($0.hands[0].points[8].x - frame(0).hands[0].points[8].x) > 0.03 },
            "Completed gesture includes the changing handshape, not only the final hold")
        for t in stride(from: 2050, through: 3600, by: 50) {
            let x: Float = (2150...2800).contains(t) ? 0.5 + Float(t - 2150) / 4000 : 0.5
            if let complete = articulating.update(frame(t, x: x)) { articulated.append(complete) }
        }
        check(articulated.count == 2, "A fresh movement rearms without removing the hands")
        for loss in [frame(500, hands: false), frame(500, body: false)] {
            var interrupted = BasicSignSegmentation()
            for t in stride(from: 0, through: 450, by: 50) { _ = interrupted.update(frame(t)) }
            check(interrupted.update(loss) == nil, "Tracking loss is not sign completion")
            var fresh: [[SkeletonFrame]] = []
            for t in stride(from: 550, through: 1550, by: 50) {
                if let complete = interrupted.update(frame(t)) { fresh.append(complete) }
            }
            check(fresh.count == 1 && fresh[0][0].timestampMS >= 550, "No pre-loss evidence leaks into the next gesture")
        }

        // FULL and TAIL share their ending. A completed query must keep the
        // earlier movement even when the bank's preview window is only 400 ms.
        let full = stride(from: 0, through: 3000, by: 50).map { t in
            frame(t, x: t < 1800 ? 0.5 + 0.08 * sin(Float(t) / 200) : 0.5)
        }
        let tail = full.filter { $0.timestampMS >= 2400 }
        let refs = [BasicReference(id: "full", label: "FULL", split: "train", signer: "synthetic", frames: full),
                    BasicReference(id: "tail", label: "TAIL", split: "train", signer: "synthetic", frames: tail)]
        let bank = BasicReferenceBank(version: 2, labels: ["FULL", "TAIL"], maxDistance: 0.1, minMargin: 0.01,
            references: refs, windowMS: 400, ruleWeight: 0, queryFrames: 4)
        let matcher = try BasicSignMatcher(bank: bank)
        check(matcher.candidate(full).label == "TAIL", "Control: rolling preview sees the shared stationary ending")
        let whole = matcher.candidate(full, completed: true)
        check(whole.label == "FULL" && whole.distance < 0.0001, "Completed matching uses the whole gesture")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("references.json")
        try JSONEncoder().encode(bank).write(to: url)
        let live = BasicLiveRecognition(referenceURL: url)
        var events: [BasicLivePrediction] = []
        live.onPrediction = { events.append($0) }
        live.load()
        let deadline = Date().addingTimeInterval(5)
        while live.loading && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        check(live.ready, "Asynchronous matcher loads the synthetic reference bank")
        for t in stride(from: 0, through: 350, by: 50) {
            live.receive(frame(t))
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        let previews = events.filter { $0.phase == .preview && $0.label != nil }
        check(!previews.isEmpty && previews.allSatisfy { $0.attemptID != nil && !$0.candidates.isEmpty },
              "Usable rolling choices carry an attempt before gesture completion")
        check(events.allSatisfy { $0.phase != .completed }, "Review availability does not wait for a completion")
        let attempt = previews.last!.attemptID
        for t in stride(from: 400, through: 1600, by: 50) {
            live.receive(frame(t))
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        check(events.filter { $0.phase == .completed }.map(\.attemptID) == [attempt],
              "Rolling and completed results share an attempt identity")
        check(events.filter { $0.label != nil }.allSatisfy { $0.attemptID == attempt },
              "A held pose cannot reopen a confirmed or rejected attempt")
        live.reset()
        events = []
        // Withhold the main run loop: a preview job is still busy when this
        // gesture finishes. The complete segment must be queued, not discarded.
        for t in stride(from: 0, through: 1000, by: 50) { live.receive(frame(t)) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let completions = events.filter { $0.phase == .completed }
        check(completions.count == 1 && completions[0].label == "TAIL", "Completion survives a busy preview worker")
        check(completions[0].attemptID != nil && completions[0].candidates.first?.label == completions[0].label,
            "Final event carries an attempt identity and matching ranked choices")
        check(completions[0].matched == false, "Rolling-window calibration is not claimed for completed segments")
        check(completions[0].timestampMS! <= 1000, "Completion retains the actual input timestamp")
        for t in stride(from: 1050, through: 1800, by: 50) { live.receive(frame(t)) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        check(events.filter { $0.phase == .completed }.count == 1, "Holding a completed sign cannot emit another attempt")
        live.reset()
        events = []
        for t in stride(from: 2000, through: 3000, by: 50) { live.receive(frame(t)) }
        live.reset()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        check(events.allSatisfy { $0.phase == .cleared }, "Reset cancels both queued and in-flight completions")

        // Slow movement used to yield only its final static hold. Preserve the
        // observations before onset detection without lowering motion thresholds.
        var slow = BasicSignSegmentation()
        var slowSegments: [[SkeletonFrame]] = []
        for t in stride(from: 0, through: 4000, by: 50) {
            let progress = min(1, max(0, Float(t - 300) / 2100))
            if let complete = slow.update(frame(t, x: 0.5 + 0.06 * progress)) { slowSegments.append(complete) }
        }
        check(!slowSegments.isEmpty && slowSegments[0].first!.timestampMS == 0,
              "Late onset detection retains the beginning of the observed attempt")
        print("PASS: \(checks) segmented recognition checks (synthetic, not ASL accuracy)")
    }
}
