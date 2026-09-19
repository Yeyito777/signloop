import Foundation

/// Local-only policy parity. Report stays on disk; no samples/IDs are printed.
@main
struct StreamingReplay {
    struct Event: Decodable {
        let reset: Bool
        let label: String?
        let expected: String?
    }
    struct Run: Decodable { let events: [Event] }
    struct Report: Decodable { let runs: [Run] }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "Usage: streaming-replay report.json", code: 1)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let report = try JSONDecoder().decode(Report.self, from: data)
        var count = 0
        for run in report.runs {
            var filter = LiveSignFilter()
            for event in run.events {
                let actual: String?
                if event.reset {
                    filter.reset()
                    actual = nil
                } else {
                    actual = filter.update(event.label)
                }
                guard actual == event.expected else {
                    throw NSError(domain: "Python/Swift streaming policy mismatch", code: 2)
                }
                count += 1
            }
        }
        print("PASS: Swift LiveSignFilter matches \(count) events across \(report.runs.count) local replays")
    }
}
