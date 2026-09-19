import Foundation

@main
struct LiveWindowTests {
    static func frame(_ time: Int, hands: Bool = true, mirrored: Bool = true) -> LandmarkFrame {
        LandmarkFrame(timestampMS: time, hands: hands ? [
            TrackedHand(handedness: "Right", handednessScore: 0.9,
                        joints: (0..<21).map { Joint(x: Float($0)*0.01, y: 0.5, z: 0) })
        ] : [], imageAspectRatio: 0.5625, mirrored: mirrored)
    }
    static func result(_ label: String?, score: Float = 0.9) -> Classification {
        Classification(candidates: label.map { [.init(label: $0, score: score)] } ?? [],
                       unknown: label == nil)
    }
    static func require(_ value: Bool, _ message: String) {
        if !value { fatalError(message) }
    }
    static func firstJob(_ policy: inout LiveWindowPolicy, start: Int = 0) -> LiveWindowPolicy.Job {
        for t in stride(from: start, through: start+600, by: 42) {
            if let job = policy.ingest(frame(t), nowMS: t) { return job }
        }
        fatalError("No inference after sufficient history")
    }
    static func nextJob(_ policy: inout LiveWindowPolicy, after time: Int) -> LiveWindowPolicy.Job {
        for t in stride(from: time+42, through: time+650, by: 42) {
            if let job = policy.ingest(frame(t), nowMS: t) { return job }
        }
        fatalError("Cadence stalled")
    }
    static func main() {
        var policy = LiveWindowPolicy()
        let a = firstJob(&policy)
        require(a.frames.count >= 6, "Short window inferred")
        policy.complete(a, result: result("HELLO"), nowMS: a.timestampMS+10)
        require(policy.visible == nil, "Single estimate was displayed")
        let b = nextJob(&policy, after: a.timestampMS)
        require(b.timestampMS-a.timestampMS >= 250, "Inference exceeded 4Hz")
        policy.complete(b, result: result("HELLO"), nowMS: b.timestampMS+10)
        require(policy.visible == "HELLO", "Agreement failed to display")
        let c = nextJob(&policy, after: b.timestampMS)
        policy.complete(c, result: result(nil), nowMS: c.timestampMS+10)
        require(policy.visible == nil, "Unknown did not clear")
        print("PASS: cadence, two confirmations, unknown clearing")

        for action in ["pause", "noHands", "flip", "gap", "outOfOrder", "stale", "future"] {
            var p = LiveWindowPolicy()
            let job = firstJob(&p)
            switch action {
            case "pause": p.reset()
            case "noHands": _ = p.ingest(frame(job.timestampMS+42, hands: false), nowMS: job.timestampMS+42)
            case "flip": _ = p.ingest(frame(job.timestampMS+42, mirrored: false), nowMS: job.timestampMS+42)
            case "gap": _ = p.ingest(frame(job.timestampMS+250), nowMS: job.timestampMS+250)
            case "outOfOrder": _ = p.ingest(frame(job.timestampMS), nowMS: job.timestampMS+20)
            case "future": _ = p.ingest(frame(job.timestampMS+100), nowMS: job.timestampMS)
            default: _ = p.ingest(frame(job.timestampMS+42), nowMS: job.timestampMS+500)
            }
            require(p.isBusy, "Reset released an unfinished job; creates queued backlog")
            require(!p.complete(job, result: result("HELLO"), nowMS: job.timestampMS+300),
                    "Superseded camera generation accepted")
            require(!p.isBusy && p.visible == nil, "Stale completion corrupted state")
            require(!p.complete(job, result: result("HELLO"), nowMS: job.timestampMS+300),
                    "Duplicate callback accepted")
        }
        print("PASS: pause, release, flip, gaps and delayed callback invalidation")

        var slow = LiveWindowPolicy()
        let hanging = firstJob(&slow)
        for t in stride(from: hanging.timestampMS+42, through: 10_000, by: 42) {
            require(slow.ingest(frame(t), nowMS: t) == nil, "Queued behind slow inference")
            require(slow.bufferedCount <= 30, "Latest buffer grew unbounded")
        }
        require(!slow.complete(hanging, result: result("YES"), nowMS: 10_000), "Old response accepted")
        require(!slow.isBusy, "Slow completion permanently blocked scheduling")
        print("PASS: hung inference produces no backlog or stale result")

        for label in ["UNSUPPORTED:cat", "I_LOVE_YOU"] {
            var p = LiveWindowPolicy()
            let first = firstJob(&p)
            p.complete(first, result: result(label), nowMS: first.timestampMS)
            let second = nextJob(&p, after: first.timestampMS)
            p.complete(second, result: result(label), nowMS: second.timestampMS)
            require(p.visible == nil, "Unexpected label accepted by temporal path")
        }
        for score in [Float.nan, Float.infinity, -0.1, 1.1] {
            var p = LiveWindowPolicy()
            let j = firstJob(&p)
            p.complete(j, result: result("NO", score: score), nowMS: j.timestampMS)
            require(p.visible == nil, "Malformed score accepted")
        }
        print("PASS: allowed-label and finite-score rejection")

        var expiring = LiveWindowPolicy()
        let e1 = firstJob(&expiring)
        expiring.complete(e1, result: result("YES"), nowMS: e1.timestampMS)
        let e2 = nextJob(&expiring, after: e1.timestampMS)
        expiring.complete(e2, result: result("YES"), nowMS: e2.timestampMS)
        let e3 = nextJob(&expiring, after: e2.timestampMS)
        // Camera continues while model hangs: old visible output still expires.
        _ = expiring.ingest(frame(e2.timestampMS+390), nowMS: e2.timestampMS+390)
        expiring.expire(nowMS: e2.timestampMS+401)
        require(expiring.visible == nil && expiring.isBusy, "Inference stall kept old caption")
        expiring.reset()
        require(!expiring.complete(e3, result: result("YES"), nowMS: e3.timestampMS+10), "Reset bypassed")
        print("PASS: independent camera/model staleness watchdog")

        for step in [16, 33, 42, 67, 100] {
            let input = stride(from: 0, through: 1200, by: step).map { frame($0) }
            let sampled = LiveWindowPolicy.resample(input)
            let times = sampled.map(\.timestampMS)
            require(Set(times).count == times.count && times == times.sorted(), "Duplicate/unordered resampling")
            require(times.last == input.last?.timestampMS, "Latest observation missing")
            require(times.allSatisfy { t in input.contains { $0.timestampMS == t } }, "Invented frame")
            require(sampled.count <= 19, "Model input rate exceeds research cadence")
        }
        print("PASS: causal resampling across 10–60 FPS")

        var soak = LiveWindowPolicy()
        var calls = 0
        for t in stride(from: 0, through: 60_000, by: 42) {
            if let job = soak.ingest(frame(t), nowMS: t) {
                calls += 1
                require(job.frames.count <= 19, "Long-session inference window grew")
                soak.complete(job, result: result("PLEASE"), nowMS: t+8)
            }
        }
        require((230...240).contains(calls), "Unexpected steady-state cadence")
        require(soak.visible == "PLEASE", "Long-session state drift")
        print("PASS: simulated 60-second stream, \(calls) requests, bounded memory")
    }
}
