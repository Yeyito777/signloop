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
            let feature = BasicFeature(hands: [[Float](repeating: Float(i), count: 42), nil],
                body: [[Float](repeating: Float(i), count: 4), nil], face: nil, time: 0)
            refs.append(BasicReference(id: "synthetic-\(i)", label: labels[i], split: "train",
                signer: "synthetic-train", frames: [], features: Array(repeating: feature, count: 16)))
        }
        let bank = BasicReferenceBank(version: 1, labels: labels, maxDistance: 0.08, minMargin: 0.15, references: refs)
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
