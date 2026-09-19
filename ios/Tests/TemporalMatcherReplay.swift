import Foundation

/// Desktop local-only parity/performance test. Never installs reference data.
@main
struct TemporalMatcherReplay {
    struct Expected: Decodable {
        struct Match: Decodable { let label: String; let distance: Double }
        let candidates: [Match]
        let unknown: Bool
        let reason: String
    }
    struct Query: Decodable {
        let frames: [LandmarkFrame]
        let expected: Expected?
        let invalid: Bool
    }
    struct Fixture: Decodable {
        let references: [TemporalReferenceMatcher.Reference]
        let maxDistance: Double
        let minMargin: Double
        let queries: [Query]
    }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: message, code: 1) }
    }
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "Usage: temporal-replay local-fixture.json", code: 1)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        let matcher = try TemporalReferenceMatcher(references: fixture.references,
                                                  maxDistance: fixture.maxDistance,
                                                  minMargin: fixture.minMargin)
        var timings: [Double] = []
        for query in fixture.queries {
            let start = ProcessInfo.processInfo.systemUptime
            let actual: TemporalReferenceMatcher.Decision
            do {
                actual = try matcher.classify(query.frames)
            } catch TemporalReferenceMatcher.Failure.invalidFrames {
                try require(query.invalid, "Native matcher unexpectedly rejected frames")
                continue
            }
            timings.append((ProcessInfo.processInfo.systemUptime-start)*1000)
            try require(!query.invalid, "Native matcher accepted invalid frames")
            guard let expected = query.expected else {
                throw NSError(domain: "Missing expected decision", code: 1)
            }
            try require(actual.unknown == expected.unknown, "Rejection parity mismatch")
            try require(actual.reason == expected.reason, "Reason parity mismatch")
            try require(actual.candidates.count == expected.candidates.count, "Candidate count mismatch")
            for candidate in expected.candidates {
                let match = actual.candidates.first { $0.label == candidate.label }
                try require(match != nil, "Missing candidate")
                // Swift camera coordinates use Float. Python research data may
                // preserve more precision; compare with a small absolute tolerance.
                try require(abs(match!.distance-candidate.distance) < 0.00002, "Distance parity mismatch")
            }
            if !actual.unknown {
                try require(actual.candidates.first?.label == expected.candidates.first?.label,
                            "Accepted label parity mismatch")
            }
        }
        for (distance, margin) in [(-1.0, 0.1), (11, 0.1), (0.5, -1), (0.5, 2),
                                    (.nan, 0.1), (0.5, .infinity)] {
            do {
                _ = try TemporalReferenceMatcher(references: fixture.references,
                                                 maxDistance: distance, minMargin: margin)
                throw NSError(domain: "Invalid configuration accepted", code: 1)
            } catch TemporalReferenceMatcher.Failure.invalidConfiguration { }
        }
        do {
            _ = try TemporalReferenceMatcher(references: [], maxDistance: 1, minMargin: 0.1)
            throw NSError(domain: "Empty references accepted", code: 1)
        } catch TemporalReferenceMatcher.Failure.invalidConfiguration { }
        let first = fixture.references[0]
        let clone = TemporalReferenceMatcher.Reference(id: "different-id", label: "OTHER",
                                                        frames: first.frames)
        let ambiguous = try TemporalReferenceMatcher(references: [first, clone],
                                                     maxDistance: 1, minMargin: 0.1)
        try require(try ambiguous.classify(first.frames).unknown, "Ambiguous references accepted")
        let exactTie = try TemporalReferenceMatcher(references: [first, clone],
                                                    maxDistance: 1, minMargin: 0)
        try require(try exactTie.classify(first.frames).candidates.first?.label == first.label,
                    "Equal-distance ordering differs from Python")
        do {
            _ = try TemporalReferenceMatcher(references: [first, first], maxDistance: 1, minMargin: 0.1)
            throw NSError(domain: "Duplicate references accepted", code: 1)
        } catch TemporalReferenceMatcher.Failure.invalidConfiguration { }
        do {
            let emptyReference = TemporalReferenceMatcher.Reference(id: "empty", label: "OTHER", frames: [])
            _ = try TemporalReferenceMatcher(references: [first, emptyReference],
                                             maxDistance: 1, minMargin: 0.1)
            throw NSError(domain: "Unusable reference accepted", code: 1)
        } catch TemporalReferenceMatcher.Failure.unusableReference { }
        // NaN/Infinity cannot be represented in valid JSON, but may appear in
        // in-memory camera inputs: the engine must reject them without a trap.
        for value in [Float.nan, .infinity] {
            var frames = first.frames
            frames[0].imageAspectRatio = value
            do {
                _ = try matcher.classify(frames)
                throw NSError(domain: "Nonfinite input accepted", code: 1)
            } catch TemporalReferenceMatcher.Failure.invalidFrames { }
        }
        // Verify the same protocol used by the app, not just its math engine.
        let classifier: any SignClassifier = NativeTemporalClassifier(matcher: matcher)
        let empty = try await classifier.classify(frames: [])
        try require(empty.unknown && empty.candidates.isEmpty &&
                    empty.model == TemporalReferenceMatcher.modelName, "Native adapter mismatch")
        for query in fixture.queries where !query.invalid {
            let result = try await classifier.classify(frames: query.frames)
            try require(result.unknown == query.expected?.unknown, "Adapter rejection mismatch")
            for candidate in result.candidates {
                let expected = query.expected?.candidates.first { $0.label == candidate.label }
                try require(expected != nil &&
                            abs(Double(candidate.score)-exp(-expected!.distance)) < 0.00002,
                            "Adapter similarity mismatch")
            }
        }
        let sorted = timings.sorted()
        let mean = timings.reduce(0, +)/Double(max(1, timings.count))
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count-1, Int(ceil(Double(sorted.count)*0.95))-1)]
        print("PASS: native DTW decisions/distances match \(fixture.queries.count) local queries; configuration guards passed")
        print(String(format: "Desktop optimized Swift: mean %.3f ms, p95 %.3f ms (%d measured queries). NOT iPhone/camera latency.",
                     mean, p95, timings.count))
    }
}
