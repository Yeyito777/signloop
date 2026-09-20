import Foundation

/// Offline policy experiment, not an ASL accuracy benchmark. Uses the shipping
/// feature extractor, matcher and segmenter with a virtual capture/worker clock.
/// Synthetic classes deliberately have no ASL names. Optional real inputs must
/// remain local; the tool refuses train/evaluation signer overlap.
#if !GESTURE_REPLAY_CHECK
@main
#endif
struct CompareGesturePolicies {
    struct Clip {
        let id: String, label: String, profile: String
        let frames: [SkeletonFrame]
        let endMS: Int? // Known only for generated gestures, never guessed for real clips.
    }
    struct Event: Codable {
        let readyMS: Double, observedMS: Int, phase: String, choices: [String]
        var attemptID: Int? = nil
    }
    struct Cost: Codable {
        let phase: String, ms: Double
    }
    struct Row: Codable {
        let id: String, label: String, profile: String, policy: String
        let repetition: Int, endMS: Int?, durationMS: Int
        let events: [Event], costs: [Cost]
        let segments: Int, stale: Int, invalidated: Int, overflows: Int
    }
    struct Report: Codable {
        let scope: String, labels: [String], references: Int
        let rows: [Row]
    }
    struct Request { let frames: [SkeletonFrame]; let completed: Bool; var attemptID: Int? = nil }
    struct Job {
        let request: Request, candidate: BasicCandidate, generation: Int
        let start: Double, finish: Double
    }

    /// Mirrors BasicLiveRecognition's queue, cadence, invalidation and freshness
    /// rules. Both policies share all rules except segmentation/final requests.
    /// Actual matcher time is measured; --service-ms supplies a worker delay floor.
    static func replay(_ clip: Clip, matcher: BasicSignMatcher, segmented: Bool,
                       repetition: Int, serviceMS: Double, liveReview: Bool = false) -> Row {
        var frames: [SkeletonFrame] = [], pending: [Request] = []
        var segmentation = BasicSignSegmentation()
        var lastRequest = -1000, generation = 0, observed: Int?
        var nextAttemptID = 0, currentAttemptID: Int?
        var job: Job?, events: [Event] = [], costs: [Cost] = []
        var segments = 0, stale = 0, invalidated = 0, overflows = 0
        func clear(_ now: Double) {
            events.append(Event(readyMS: now, observedMS: Int(now), phase: "cleared", choices: []))
        }
        func reset(_ now: Double) {
            generation += 1; frames.removeAll(keepingCapacity: true)
            lastRequest = -1000; observed = nil; pending.removeAll(keepingCapacity: true)
            segmentation.reset(); clear(now)
            currentAttemptID = nil
        }
        func start(_ request: Request, at now: Double) {
            guard let last = request.frames.last else { return }
            lastRequest = frames.last?.timestampMS ?? last.timestampMS
            let before = ProcessInfo.processInfo.systemUptime
            let candidate = matcher.candidate(request.frames, completed: request.completed)
            let ms = (ProcessInfo.processInfo.systemUptime - before) * 1000
            costs.append(Cost(phase: request.completed ? "completed" : "preview", ms: ms))
            job = Job(request: request, candidate: candidate, generation: generation,
                      start: now, finish: now + max(serviceMS, ms))
        }
        func finish(until deadline: Double) {
            while let current = job, current.finish <= deadline {
                job = nil
                let last = current.request.frames.last!.timestampMS
                if current.generation != generation { invalidated += 1 }
                else if current.finish-current.start >= 600
                    || (frames.last?.timestampMS ?? last)-last > 1000
                    || current.finish-Double(last) > 1000 {
                    // Includes the native bridge's wall-clock input-age gate.
                    stale += 1; clear(current.finish)
                } else {
                    let choices = current.candidate.scores.filter { $0.measuredDistance != nil }
                        .sorted { $0.distance == $1.distance ? $0.label < $1.label : $0.distance! < $1.distance! }
                        .prefix(3).map(\.label)
                    events.append(Event(readyMS: current.finish, observedMS: last,
                        phase: current.request.completed ? "completed" : "preview", choices: choices,
                        attemptID: current.request.attemptID))
                }
                if !pending.isEmpty { start(pending.removeFirst(), at: current.finish) }
            }
        }
        for frame in clip.frames {
            let t = frame.timestampMS
            finish(until: Double(t))
            if let previous = frames.last, t <= previous.timestampMS || t-previous.timestampMS > 400 { reset(Double(t)) }
            if let previous = observed, t-previous > 300 { reset(Double(t)) }
            if !frame.hands.isEmpty && frame.hasSigningPose { observed = t }
            frames.append(frame); frames.removeAll { $0.timestampMS < t-2400 }
            if frames.count > 60 { frames.removeFirst(frames.count-60) }
            if frame.hands.isEmpty || !frame.hasSigningPose { reset(Double(t)); continue }
            let complete = segmented ? segmentation.update(frame) : nil
            if segmentation.startsAttempt || currentAttemptID == nil {
                nextAttemptID += 1
                currentAttemptID = nextAttemptID
            }
            if let complete {
                segments += 1
                if pending.count >= 4 { overflows += 1; reset(Double(t)); continue }
                pending.append(Request(frames: complete, completed: true, attemptID: currentAttemptID))
            }
            if !pending.isEmpty {
                if job == nil { start(pending.removeFirst(), at: Double(t)) }
            } else if job == nil && t-lastRequest >= 100 {
                start(Request(frames: frames, completed: false, attemptID: currentAttemptID), at: Double(t))
            }
        }
        finish(until: Double((clip.frames.last?.timestampMS ?? 0)+1000))
        return Row(id: clip.id, label: clip.label, profile: clip.profile,
            policy: segmented ? (liveReview ? "hybrid" : "segmented") : "rolling", repetition: repetition,
            endMS: clip.endMS, durationMS: clip.frames.last!.timestampMS,
            events: events, costs: costs, segments: segments, stale: stale,
            invalidated: invalidated, overflows: overflows)
    }

    struct Profile {
        let name: String, duration: Int, preroll: Int, hold: Int, step: Int
        var noise: Float = 0.0004
        var dropout = false, bodyDropout = false, frameDrops = false
    }
    static let profiles = [
        Profile(name: "normal", duration: 900, preroll: 300, hold: 1100, step: 42),
        Profile(name: "fast", duration: 250, preroll: 150, hold: 1100, step: 42),
        Profile(name: "slow", duration: 2100, preroll: 300, hold: 1100, step: 42),
        Profile(name: "no_hold", duration: 900, preroll: 300, hold: 0, step: 42),
        Profile(name: "short_hold", duration: 900, preroll: 300, hold: 150, step: 42),
        Profile(name: "low_fps", duration: 900, preroll: 300, hold: 1100, step: 100),
        Profile(name: "jitter", duration: 900, preroll: 300, hold: 1100, step: 42, noise: 0.003),
        Profile(name: "hand_dropout", duration: 900, preroll: 300, hold: 1100, step: 42, dropout: true),
        Profile(name: "body_dropout", duration: 900, preroll: 300, hold: 1100, step: 42, bodyDropout: true),
        Profile(name: "frame_drops", duration: 900, preroll: 300, hold: 1100, step: 42, frameDrops: true),
    ]
    static func label(_ kind: Int) -> String { String(format: "TOY_%02d", kind) }

    // Classes: five holds; horizontal/vertical/circular/out-and-back motion;
    // finger articulation; palm rotation. Motion classes share the open-hand
    // ending, making lost temporal evidence observable without ASL assumptions.
    static func sample(_ kind: Int, t: Int, profile p: Profile, signer: Int) -> SkeletonFrame {
        let u = min(1, max(0, Float(t-p.preroll)/Float(p.duration)))
        let a = Float.pi*2*u
        let scale: Float = 0.92 + Float(signer % 5)*0.035
        let offset: Float = Float(signer % 3-1)*0.012
        var x: Float = 0.46+offset, y: Float = 0.43
        if kind == 5 { x += 0.13*scale*u }
        if kind == 6 { y -= 0.10*scale*u }
        if kind == 7 { x += 0.09*scale*sin(a); y += 0.06*scale*(1-cos(a)) }
        if kind == 8 { x += 0.13*scale*sin(Float.pi*u) }
        if kind == 12 { x += 0.10*sin(Float(t)/170); y += 0.09*cos(Float(t)/113) }
        if kind == 14 { x += 0.12*u; y += 0.11*u }
        let rotate = kind == 10 ? 1.2*sin(Float.pi*u) : 0
        var points = [SkeletonPoint(id: 0, x: x, y: y, z: 0)]
        for finger in 0..<5 {
            var extensionAmount: Float = 1
            if kind == 1 { extensionAmount = 0.13 }
            if kind == 2 && finger != 1 && finger != 2 { extensionAmount = 0.18 }
            if kind == 3 && finger != 1 { extensionAmount = 0.18 }
            if kind == 4 { extensionAmount = 0.55 }
            if kind == 9 { extensionAmount = 0.15+0.85*abs(cos(a)) }
            if kind == 11 { extensionAmount = 0.36 } // unfamiliar visible rest
            if kind == 13 { extensionAmount = finger == 4 ? 1 : 0.2 }
            for joint in 0..<4 {
                let id = finger*4+joint+1
                let baseX = (Float(finger)-2)*0.024
                let dx = baseX + (finger == 0 ? -0.014*Float(joint) : 0)
                let dy = -0.042 - Float(joint)*0.021*extensionAmount
                let dz = Float(joint)*0.022*(1-extensionAmount)
                let n = p.noise*sin(Float(t*13+id*77+signer*113)*0.17)
                points.append(SkeletonPoint(id: id,
                    x: x+scale*(dx*cos(rotate)-dz*sin(rotate))+n,
                    y: y+scale*dy+n*0.6, z: scale*(dx*sin(rotate)+dz)))
            }
        }
        let pose = [SkeletonPoint(id: 11, x: 0.35+offset, y: 0.35, z: 0),
                    SkeletonPoint(id: 12, x: 0.65+offset, y: 0.35, z: 0),
                    SkeletonPoint(id: 13, x: 0.36+offset, y: 0.55, z: 0),
                    SkeletonPoint(id: 14, x: 0.64+offset, y: 0.55, z: 0),
                    SkeletonPoint(id: 15, x: x, y: y, z: 0),
                    SkeletonPoint(id: 16, x: 0.67, y: 0.6, z: 0)]
        let loss = abs(t-(p.preroll+p.duration/2)) < p.step
        let absent = kind == 15 || t > p.preroll+p.duration+p.hold || (p.dropout && loss)
        return SkeletonFrame(timestampMS: t, width: 720, height: 1280, camera: "synthetic-policy-benchmark",
            hands: absent ? [] : [SkeletonHand(points: points, modelHandedness: "Right", handednessScore: 1, poseSide: "Left")],
            pose: p.bodyDropout && loss ? [] : pose, face: [], expressions: [:], timingsMS: [:])
    }
    static func generatedFrames(_ kind: Int, _ profile: Profile, _ signer: Int, training: Bool = false) -> [SkeletonFrame] {
        let end = profile.preroll+profile.duration+(training ? 100 : profile.hold)
        let tail = !training && profile.hold < 200 ? 500 : 0
        return stride(from: 0, through: end+tail, by: profile.step).enumerated().compactMap { i, t in
            if profile.frameDrops && i % 5 == 2 { return nil }
            return sample(kind, t: t, profile: profile, signer: signer)
        }
    }
    static func synthetic() -> (BasicReferenceBank, [Clip]) {
        let labels = (0..<11).map(label)
        var references: [BasicReference] = []
        for kind in 0..<11 {
            for signer in 0..<(kind == 0 ? 6 : 5) {
                let p = Profile(name: "train", duration: 800+signer*50, preroll: 200, hold: 100, step: 42)
                references.append(BasicReference(id: "train-\(kind)-\(signer)", label: label(kind), split: "train",
                    signer: "generated-train-\(signer)", frames: generatedFrames(kind, p, signer, training: true)))
            }
        }
        var clips: [Clip] = []
        for p in profiles {
            for kind in 0..<16 {
                for signer in 10..<14 {
                    clips.append(Clip(id: "\(p.name)-\(kind)-\(signer)", label: kind < 11 ? label(kind) : "UNKNOWN",
                        profile: p.name, frames: generatedFrames(kind, p, signer), endMS: p.preroll+p.duration))
                }
            }
        }
        return (BasicReferenceBank(version: 2, labels: labels, maxDistance: 0, minMargin: 1,
            references: references, windowMS: 1200, ruleWeight: 0, queryFrames: 4), clips)
    }

    static func main() throws {
        let args = CommandLine.arguments
        func value(_ key: String) -> String? {
            args.firstIndex(of: key).flatMap { args.indices.contains($0+1) ? args[$0+1] : nil }
        }
        guard let output = value("--out") else { fatalError("Use --out path [--bank path --clips path] [--service-ms N] [--repetitions N]") }
        let bank: BasicReferenceBank, clips: [Clip], scope: String
        if let bankPath = value("--bank"), let clipsPath = value("--clips") {
            let source = try JSONDecoder().decode(BasicReferenceBank.self, from: Data(contentsOf: URL(fileURLWithPath: bankPath)))
            bank = try source.restricted(to: BasicSignScore.presentationVocabulary)
            let records = try JSONDecoder().decode([BasicReference].self, from: Data(contentsOf: URL(fileURLWithPath: clipsPath)))
            precondition(Set(records.map(\.signer)).isDisjoint(with: Set(source.references.map(\.signer))), "Train/evaluation signer overlap")
            precondition(records.allSatisfy { $0.split != "train" && !$0.frames.isEmpty })
            clips = records.map { Clip(id: $0.id, label: $0.label, profile: $0.split, frames: $0.frames, endMS: nil) }
            scope = "Previously collected real data; split provenance must be checked separately; no end-boundary annotation"
        } else { (bank, clips) = synthetic(); scope = "Synthetic geometry only, NOT real ASL or human-signing accuracy" }
        let matcher = try BasicSignMatcher(bank: bank,
            weMotionScale: bank.labels.contains("WE") ? BasicSignMatcher.compactWEMotionScale : nil)
        let repetitions = Int(value("--repetitions") ?? "3")!
        let service = Double(value("--service-ms") ?? "0")!
        // Warm both feature paths before collecting timing. Alternate policy
        // order across clips and repetitions to reduce ordering/thermal bias.
        for _ in 0..<5 { _ = matcher.candidate(clips[0].frames); _ = matcher.candidate(clips[0].frames, completed: true) }
        var rows: [Row] = []
        for repeatIndex in 0..<repetitions {
            for (i, clip) in clips.enumerated() {
                for segmented in (i+repeatIndex)%2 == 0 ? [false, true] : [true, false] {
                    rows.append(replay(clip, matcher: matcher, segmented: segmented,
                        repetition: repeatIndex, serviceMS: service, liveReview: args.contains("--live-review")))
                }
            }
            print("Finished repetition \(repeatIndex+1)/\(repetitions): \(clips.count) clips, both policies")
            fflush(stdout)
        }
        let report = Report(scope: scope, labels: bank.labels, references: matcher.usableReferenceCount, rows: rows)
        try JSONEncoder().encode(report).write(to: URL(fileURLWithPath: output))
        print("Saved \(rows.count) policy replays to \(output)")
    }
}
