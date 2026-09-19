import Foundation

/// Optional local-only replay of restricted research model outputs. No footage,
/// samples, identifiers, or coordinates are printed; nothing is uploaded.
@main
struct LocalGestureReplay {
    struct Frame: Decodable {
        let timestampMS: Int
        let hands: [LocalHandGesture]
    }
    struct Clip: Decodable {
        let frames: [Frame]
        let swift_expected: [Bool]
    }
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "Usage: local-replay path/to/replay.json", code: 1)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let clips = try JSONDecoder().decode([Clip].self, from: data)
        var count = 0
        for clip in clips {
            var filter = LocalGestureFilter()
            let actual = clip.frames.map {
                filter.update($0.hands, timestampMS: $0.timestampMS) != nil
            }
            guard actual == clip.swift_expected else {
                throw NSError(domain: "Python/Swift policy parity failure", code: 2)
            }
            count += clip.frames.count
        }
        print("PASS: native Swift filter matches \(count) real-model frames across \(clips.count) local clips")
    }
}
