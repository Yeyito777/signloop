import Foundation

/// Cross-check the virtual experiment against real-time, asynchronous native
/// recognition on the Mac. Generated input only; no camera/phone latency claim.
@main struct CheckGesturePolicyReplay {
    struct Result: Codable {
        let profile: String, kind: Int, expected: [CompareGesturePolicies.Event]
        let actual: [CompareGesturePolicies.Event], sameCompletions: Bool
        let maxReadyDifferenceMS: Double
    }
    struct Report: Codable {
        let cases: [Result], segmentationUpdateMS: [Double]
        let threeChoiceSortingMS: Double, sortingIterations: Int
    }
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let (bank, _) = CompareGesturePolicies.synthetic()
        let matcher = try BasicSignMatcher(bank: bank)
        let url = output.deletingLastPathComponent().appendingPathComponent("synthetic-live-check-bank.json")
        try JSONEncoder().encode(matcher.packedBank()).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = [(0, "normal"), (7, "normal"), (9, "normal"), (7, "fast"),
                       (7, "no_hold"), (7, "low_fps"), (7, "slow"), (7, "hand_dropout")]
        var results: [Result] = []
        for (kind, profileName) in samples {
            let profile = CompareGesturePolicies.profiles.first { $0.name == profileName }!
            let frames = CompareGesturePolicies.generatedFrames(kind, profile, 10)
            let clip = CompareGesturePolicies.Clip(id: "live-check", label: CompareGesturePolicies.label(kind),
                profile: profileName, frames: frames, endMS: profile.preroll+profile.duration)
            let predicted = CompareGesturePolicies.replay(clip, matcher: matcher, segmented: true,
                repetition: 0, serviceMS: 0, liveReview: true).events.filter { !$0.choices.isEmpty }
            let live = BasicLiveRecognition(referenceURL: url)
            live.load()
            let loadDeadline = Date().addingTimeInterval(5)
            while !live.ready && live.loading && Date() < loadDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            }
            precondition(live.ready, "Could not load synthetic references")
            var actual: [CompareGesturePolicies.Event] = []
            let start = ProcessInfo.processInfo.systemUptime
            live.onPrediction = { event in
                if event.label != nil && event.phase != .cleared {
                    actual.append(CompareGesturePolicies.Event(
                        readyMS: (ProcessInfo.processInfo.systemUptime-start)*1000,
                        observedMS: event.timestampMS!, phase: event.phase.rawValue,
                        choices: event.candidates.map(\.label), attemptID: event.attemptID))
                }
            }
            for frame in frames {
                let remaining = start + Double(frame.timestampMS)/1000 - ProcessInfo.processInfo.systemUptime
                if remaining > 0 { RunLoop.current.run(until: Date().addingTimeInterval(remaining)) }
                live.receive(frame)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            let same = predicted.map(\.observedMS) == actual.map(\.observedMS)
                && predicted.map(\.choices) == actual.map(\.choices)
                && predicted.map(\.phase) == actual.map(\.phase)
                && predicted.map(\.attemptID) == actual.map(\.attemptID)
            let delta = zip(predicted, actual).map { abs($0.readyMS-$1.readyMS) }.max() ?? 0
            results.append(Result(profile: profileName, kind: kind, expected: predicted,
                actual: actual, sameCompletions: same, maxReadyDifferenceMS: delta))
            print("\(profileName)/\(kind): virtual/live ranking agreement \(same), count \(actual.count), timing delta \(Int(delta))ms")
            fflush(stdout)
            live.reset()
        }
        var updateTimes: [Double] = []
        for p in CompareGesturePolicies.profiles {
            for kind in 0..<16 {
                var segmenter = BasicSignSegmentation()
                for frame in CompareGesturePolicies.generatedFrames(kind, p, 10) {
                    let start = ProcessInfo.processInfo.systemUptime
                    _ = segmenter.update(frame)
                    updateTimes.append((ProcessInfo.processInfo.systemUptime-start)*1000)
                }
            }
        }
        let scores = matcher.candidate(CompareGesturePolicies.generatedFrames(7, CompareGesturePolicies.profiles[0], 10)).scores
        var checksum = 0
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<100_000 {
            let ranked = scores.filter { $0.measuredDistance != nil }
                .sorted { $0.distance == $1.distance ? $0.label < $1.label : $0.distance! < $1.distance! }
                .prefix(3)
            checksum += ranked.reduce(0) { $0+$1.label.count }
        }
        let sortingMS = (ProcessInfo.processInfo.systemUptime-start)*1000
        precondition(checksum > 0)
        try JSONEncoder().encode(Report(cases: results, segmentationUpdateMS: updateTimes,
            threeChoiceSortingMS: sortingMS, sortingIterations: 100_000)).write(to: output)
        precondition(results.allSatisfy(\.sameCompletions), "Virtual replay differs from actual async recognizer")
    }
}
