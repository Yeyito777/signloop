import Foundation

@main struct BasicSignTests {
    static func main() throws {
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); assertions += 1
        }
        let labels = (0..<16).map { "SYNTHETIC_\($0)" }
        // Synthetic geometry tests mathematical invariants, NOT ASL accuracy.
        let hand = (0..<21).map {
            SkeletonPoint(id: $0, x: 0.5+Float($0%5)*0.015, y: 0.35-Float($0)*0.004, z: 0)
        }
        let pose = [
            SkeletonPoint(id: 11, x: 0.4, y: 0.4, z: 0),
            SkeletonPoint(id: 12, x: 0.6, y: 0.4, z: 0),
            SkeletonPoint(id: 13, x: 0.4, y: 0.5, z: 0),
            SkeletonPoint(id: 14, x: 0.6, y: 0.5, z: 0),
            SkeletonPoint(id: 15, x: 0.5, y: 0.35, z: 0),
            SkeletonPoint(id: 16, x: 0.65, y: 0.6, z: 0)]
        let frames = (0..<12).map { t in
            SkeletonFrame(timestampMS: t*67, width: 720, height: 1280, camera: "synthetic",
                hands: [SkeletonHand(points: hand, modelHandedness: "Left", handednessScore: 1, poseSide: "Left")],
                pose: pose, face: [], expressions: [:], timingsMS: [:])
        }
        var refs = [BasicReference(id: "synthetic-0", label: labels[0], split: "train",
                                   signer: "synthetic-train", frames: frames)]
        for i in 1..<16 {
            let feature = BasicFeature(hands: [[Float](repeating: Float(i), count: 63), nil],
                body: [[Float](repeating: Float(i), count: 4), nil], face: nil, time: 0)
            refs.append(BasicReference(id: "synthetic-\(i)", label: labels[i], split: "train",
                signer: "synthetic-train", frames: [], features: Array(repeating: feature, count: 16)))
        }
        let bank = BasicReferenceBank(version: 2, labels: labels, maxDistance: 0.08, minMargin: 0.15, references: refs)
        let matcher = try BasicSignMatcher(bank: bank)
        let candidate = matcher.candidate(frames)
        check(candidate.label == labels[0], "Exact synthetic temporal replay must match")
        check(candidate.distance < 0.0001, "Identity distance")
        check(matcher.accepted(candidate) == labels[0], "Known identity should pass")
        check(candidate.scores.count == 16 && candidate.scores.map(\.label) == labels, "All scores in stable vocabulary order")
        check(candidate.scores[0].similarity! > 0.999, "Exact geometry yields high similarity")
        check(candidate.scores.allSatisfy { $0.similarity.map { (0...1).contains($0) } ?? false },
              "Measured similarities finite and bounded")
        let sampleScores = BasicSignScore.rows(labels: ["A", "B", "C", "D"],
            distances: ["A": 0, "B": 0.08, "C": 0.16, "D": .infinity])
        check(sampleScores[0].similarity == 1, "Identity similarity")
        check(abs(sampleScores[1].similarity! - exp(-1)) < 0.00001, "Documented distance transform")
        check(sampleScores[1].similarity! > sampleScores[2].similarity!, "Similarity monotonically decreases")
        check(sampleScores[3].similarity == nil, "Nonfinite distance not an invented probability")
        check(BasicSignScore(label: "invalid", distance: -1).similarity == nil, "Invalid negative distance rejected")
        check(sampleScores[1].distanceText == "0.080", "UI displays distance, not an arbitrary confidence percentage")
        check(sampleScores[3].distanceText == "—", "Missing evidence has no metric")
        check(BasicSignScore(label: "invalid", distance: -1).distanceText == "—", "Invalid UI metric is unavailable")
        let ties = BasicSignScore.rows(labels: ["B", "A", "missing"], distances: ["A": 0.1, "B": 0.1])
        check(BasicSignScore.ranked(ties).map(\.label) == ["B", "A", "missing"], "Ties preserve vocabulary order")
        check(BasicSignScore.ranked(Array(sampleScores.reversed())).map(\.label) == ["A", "B", "C", "D"],
              "Closest matches sort by independent distance, missing evidence last")
        check(matcher.candidate([]).scores.count == 16, "Missing input retains all 16 rows")
        check(matcher.candidate([]).scores.allSatisfy { $0.similarity == nil }, "No hand evidence displays dashes, not percentages")
        var rejected = bank
        rejected.maxDistance = 0
        let rejectMatcher = try BasicSignMatcher(bank: rejected)
        let rejectedCandidate = rejectMatcher.candidate(frames)
        check(rejectMatcher.accepted(rejectedCandidate) == nil && rejectedCandidate.scores[0].similarity! > 0.999,
              "Scores visible even when classification is rejected")
        check(matcher.candidate([]).label == nil, "Empty unknown")
        check(matcher.candidate(Array(frames.prefix(3))).label == nil, "Insufficient evidence")
        let blank = frames.map { f in
            SkeletonFrame(timestampMS: f.timestampMS, width: f.width, height: f.height, camera: f.camera,
                          hands: [], pose: [], face: [], expressions: [:], timingsMS: [:])
        }
        check(matcher.candidate(blank).label == nil, "No observations must not force nearest class")
        check(matcher.accepted(BasicCandidate(label: labels[0], distance: 0.09, margin: 0.9)) == nil, "Distance rejection")
        check(matcher.accepted(BasicCandidate(label: labels[0], distance: 0.01, margin: 0.01)) == nil, "Margin rejection")
        let packed = matcher.packedBank()
        check(packed.references.allSatisfy { $0.frames.isEmpty }, "No raw frames in deployment asset")
        let roundTrip = try JSONDecoder().decode(BasicReferenceBank.self, from: JSONEncoder().encode(packed))
        let packedMatcher = try BasicSignMatcher(bank: roundTrip)
        check(packedMatcher.candidate(frames).distance == candidate.distance, "Packed parity")
        let focusLabels = [labels[3], labels[1], labels[2]]
        let focusBank = try bank.restricted(to: focusLabels)
        let focus = try BasicSignMatcher(bank: focusBank).candidate(frames)
        check(focusBank.labels == focusLabels && focusBank.references.count == 3,
              "Requested order retained and excluded references removed from actual search")
        check(focus.label != labels[0] && focusLabels.contains(focus.label ?? ""),
              "Even the former exact winner cannot be predicted once removed")
        check(focus.scores.map(\.label) == focusLabels, "No hidden excluded candidates in scores")
        for score in focus.scores {
            check(score.distance == candidate.scores.first { $0.label == score.label }?.distance,
                  "Restriction leaves remaining absolute scores unchanged")
        }
        check(focusBank.windowMS == bank.windowMS && focusBank.ruleWeight == bank.ruleWeight
              && focusBank.maxDistance == bank.maxDistance, "Restriction does not retune model policy")
        for invalid in [[], [labels[0]], [labels[0], labels[0]], [labels[0], "NOT_IN_BANK"]] {
            do { _ = try bank.restricted(to: invalid); fatalError("Invalid subset accepted") }
            catch { assertions += 1 }
        }
        check(BasicSignScore.presentationVocabulary == [
            "HELLO", "MY", "NAME", "TODAY", "WE", "SHOW", "PHONE",
            "PLEASE", "SORRY", "THANKYOU", "ILOVEYOU"
        ], "Presentation includes exactly script words plus I love you")
        let expandedLabels = labels + (16..<32).map { "SYNTHETIC_\($0)" }
        let expanded = BasicReferenceBank(version: 2, labels: expandedLabels, maxDistance: 0,
                                         minMargin: 1, references: refs)
        let expandedMatcher = try BasicSignMatcher(bank: expanded)
        check(expandedMatcher.candidate(frames).scores.count == 32, "32-label bank supported without changing geometry")
        check(expandedMatcher.candidate(frames).distance == candidate.distance, "Expanding vocabulary alone does not change old distances")
        // Add actual competing references, not just empty label names. Pruning
        // against the global winner would violate this for non-winning labels.
        let competitors = (16..<32).map { i in
            BasicReference(id: "competitor-\(i)", label: expandedLabels[i], split: "train",
                           signer: "synthetic-train", frames: frames)
        }
        let competingBank = BasicReferenceBank(version: 2, labels: expandedLabels, maxDistance: 0,
                                               minMargin: 1, references: refs + competitors)
        let competing = try BasicSignMatcher(bank: competingBank).candidate(frames)
        check(Array(competing.scores.prefix(16)).map(\.distance) == candidate.scores.map(\.distance),
              "Adding 16 real competitors cannot dilute ANY existing distance")
        check(Array(competing.scores.prefix(16)).map(\.similarity) == candidate.scores.map(\.similarity),
              "Adding competitors cannot dilute the legacy score transform either")
        check(competing.margin == 0 && candidate.margin > 0, "Ambiguity can increase without reducing absolute match quality")
        let reversedBank = BasicReferenceBank(version: 2, labels: expandedLabels, maxDistance: 0,
                                              minMargin: 1, references: Array((refs + competitors).reversed()))
        let reversed = try BasicSignMatcher(bank: reversedBank).candidate(frames)
        check(reversed.scores.map(\.distance)
              == competing.scores.map(\.distance), "Exact search cannot depend on reference traversal order")
        let transformed = frames.map { f in
            func transform(_ p: SkeletonPoint) -> SkeletonPoint {
                // Change aspect, image translation and scale together.
                SkeletonPoint(id: p.id, x: (p.x*0.5625*0.8+0.04)/0.75,
                              y: p.y*0.8+0.06, z: p.z)
            }
            return SkeletonFrame(timestampMS: f.timestampMS, width: 960, height: 1280, camera: f.camera,
                hands: f.hands.map { SkeletonHand(points: $0.points.map(transform), modelHandedness: $0.modelHandedness,
                                                  handednessScore: $0.handednessScore, poseSide: $0.poseSide) },
                pose: f.pose.map(transform), face: [], expressions: [:], timingsMS: [:])
        }
        check(matcher.candidate(transformed).distance < 0.0001, "Aspect/body scale/translation invariance")
        var pointing = [Float](repeating: 0, count: 63)
        // Pure geometry: a straight finger aligned with optical Z.
        for f in 0..<4 {
            let start = 5+f*4
            for j in 0..<4 {
                pointing[(start+j)*3+2] = f == 0 ? Float(j)*0.3 : (j == 1 ? 0.3 : 0)
                pointing[(start+j)*3+1] = f == 0 ? 0 : (j >= 2 ? 0.15 : 0)
            }
        }
        check(BasicSignMatcher.straightness(pointing, finger: 0) > 0.99, "Optical-axis pointing is extended, not curled")
        check(BasicSignMatcher.straightness(pointing, finger: 1) < 0.65, "Curled geometry remains curled")
        var rotated = pointing
        for i in 0..<21 {
            rotated[i*3] = pointing[i*3+2]
            rotated[i*3+2] = -pointing[i*3]
        }
        let intrinsic = BasicSignMatcher.intrinsicShape(pointing)
        let rotatedIntrinsic = BasicSignMatcher.intrinsicShape(rotated)
        check(zip(intrinsic, rotatedIntrinsic).allSatisfy { abs($0-$1) < 0.00001 },
              "Hand shape stays stable when pointing rotates toward the lens")
        let pointingFeature = BasicFeature(hands: [pointing, nil], body: [[0, 0, 0, 0], nil], face: nil, time: 0)
        check(BasicSignMatcher.anatomicalPenalty(label: "YOU", sequence: [pointingFeature]) <
              BasicSignMatcher.anatomicalPenalty(label: "MY", sequence: [pointingFeature]), "YOU shape rule differs from flat palm")
        let circle = (0..<16).map { i -> BasicFeature in
            let angle = Float(i)/15 * 2 * Float.pi
            return BasicFeature(hands: [pointing, nil],
                body: [[cos(angle)*0.35, sin(angle)*0.35, 0, 0], nil], face: nil, time: i*67)
        }
        let hold = (0..<16).map { i in
            BasicFeature(hands: [pointing, nil], body: [[0.35, 0, 0, 0], nil], face: nil, time: i*67)
        }
        check(BasicSignMatcher.trajectoryCost(circle, circle) == 0, "Temporal identity")
        check(BasicSignMatcher.trajectoryCost(circle, hold) > 0.01, "A circle cannot collapse into a static hold")
        let legacy = BasicReferenceBank(version: 1, labels: labels, maxDistance: 0.08, minMargin: 0.15,
                                        references: packed.references)
        do { try legacy.validate(); fatalError("Legacy packed feature schema accepted") } catch { assertions += 1 }
        var stability = BasicSignStability()
        check(stability.update(labels[0]) == nil, "No single-frame display")
        check(stability.update(labels[0]) == labels[0], "Consecutive display")
        check(stability.update(nil) == nil, "Unknown clears")
        check(stability.update(labels[0]) == nil, "Unknown breaks confirmation")
        stability.reset()
        check(stability.update(labels[0]) == nil, "Pause breaks confirmation")
        let bad = BasicReferenceBank(version: 1, labels: labels, maxDistance: 0.08, minMargin: 0.15,
            references: [BasicReference(id: "forbidden", label: labels[0], split: "test", signer: "heldout", frames: frames)])
        do { try bad.validate(); fatalError("Evaluation data accepted as reference") } catch { assertions += 1 }
        do { _ = try bad.restricted(to: [labels[1], labels[2]]); fatalError("Filtering hid forbidden data") }
        catch { assertions += 1 }
        // Exercise the real asynchronous app adapter, without any camera/data.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("synthetic-references.json")
        try JSONEncoder().encode(packed).write(to: url)
        let live = BasicLiveRecognition(referenceURL: url)
        live.load()
        let deadline = Date().addingTimeInterval(5)
        while !live.ready && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        check(live.ready && live.labels == labels, "Real adapter loads compact bank")
        check(live.scores.count == 16 && live.scores.allSatisfy { $0.similarity == nil }, "Bank loads without invented observations")
        for frame in frames {
            live.receive(frame)
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        check(live.sign == labels[0], "Real adapter confirms synthetic identity")
        check(live.scores.count == 16 && live.scores[0].similarity! > 0.999, "Real adapter publishes every label's score")
        let restrictedLive = BasicLiveRecognition(referenceURL: url, activeLabels: [labels[0], labels[3], labels[4]])
        check(restrictedLive.labels.count == 3 && restrictedLive.scores.count == 3,
              "Startup already shows only requested vocabulary")
        restrictedLive.load()
        let restrictedDeadline = Date().addingTimeInterval(5)
        while !restrictedLive.ready && Date() < restrictedDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        check(restrictedLive.ready && restrictedLive.labels == [labels[0], labels[3], labels[4]],
              "Real adapter loads a restricted bank from full private file")
        for frame in frames {
            restrictedLive.receive(frame)
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        check(restrictedLive.sign == labels[0] && restrictedLive.scores.count == 3,
              "Live inference and display both use restricted vocabulary")
        restrictedLive.reset()
        check(restrictedLive.scores.count == 3 && restrictedLive.scores.allSatisfy { $0.distance == nil },
              "Reset cannot restore excluded labels")
        let uncertainURL = folder.appendingPathComponent("uncertain.json")
        var uncertainBank = packed
        uncertainBank.maxDistance = 0
        try JSONEncoder().encode(uncertainBank).write(to: uncertainURL)
        let uncertain = BasicLiveRecognition(referenceURL: uncertainURL)
        uncertain.load()
        let uncertainDeadline = Date().addingTimeInterval(5)
        while !uncertain.ready && Date() < uncertainDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        for frame in frames {
            uncertain.receive(frame)
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        check(uncertain.sign == labels[0] && uncertain.detail.contains("uncertain"),
              "Top candidate remains visible below confidence gate, explicitly uncertain")
        var next = frames.last!
        // Codable timestamp is immutable, so form a new late frame explicitly.
        next = SkeletonFrame(timestampMS: 1000, width: next.width, height: next.height,
            camera: next.camera, hands: next.hands, pose: next.pose, face: next.face,
            expressions: next.expressions, timingsMS: [:])
        live.receive(next)
        live.reset() // main-thread completion cannot run before this invalidation
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        check(live.sign == nil, "Late worker cannot resurrect a paused sign")
        check(live.scores.allSatisfy { $0.similarity == nil }, "Late worker cannot resurrect stale scores")
        live.receive(blank.last!)
        check(live.sign == nil, "Hand loss clears caption")
        check(live.scores.count == 16 && live.scores.allSatisfy { $0.similarity == nil }, "Hand loss clears all scores")
        print("PASS: \(assertions) basic temporal matcher invariants (synthetic, not ASL accuracy)")
    }
}
