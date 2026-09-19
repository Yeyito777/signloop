import Foundation

@main struct BasicSignReplay {
    struct Event: Codable {
        let timestamp: Int
        let label: String?
        let distance: Float
        let margin: Float
    }
    struct Row: Codable {
        let id: String
        let label: String
        let split: String
        let events: [Event]
        let elapsedMS: Double
    }
    static func main() throws {
        let args = CommandLine.arguments
        let bank = try JSONDecoder().decode(BasicReferenceBank.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        let matcher = try BasicSignMatcher(bank: bank)
        if args.count == 4 && args[2] == "--pack" {
            try JSONEncoder().encode(matcher.packedBank()).write(to: URL(fileURLWithPath: args[3]), options: .atomic)
            print("Packed \(matcher.usableReferenceCount) usable private references")
            return
        }
        let clips = try JSONDecoder().decode([BasicReference].self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
        guard Set(clips.map(\.signer)).isDisjoint(with: Set(bank.references.map(\.signer))) else {
            fatalError("Training/evaluation signer overlap")
        }
        var rows: [Row] = []
        for clip in clips {
            var frames: [SkeletonFrame] = []
            var events: [Event] = []
            var last = -1000
            let start = Date()
            for frame in clip.frames {
                frames.append(frame)
                frames.removeAll { $0.timestampMS < frame.timestampMS-2400 }
                // The live adapter clears confirmation immediately on every
                // hand/pose-loss frame, even between scheduled match requests.
                if frame.hands.isEmpty || !frame.hasPose {
                    events.append(Event(timestamp: frame.timestampMS, label: nil, distance: 999, margin: 0))
                    continue
                }
                if frame.timestampMS-last < 100 { continue }
                last = frame.timestampMS
                let c = matcher.candidate(frames)
                events.append(Event(timestamp: frame.timestampMS, label: c.label,
                                    distance: c.distance, margin: c.margin))
            }
            rows.append(Row(id: clip.id, label: clip.label, split: clip.split,
                            events: events, elapsedMS: -start.timeIntervalSinceNow*1000))
        }
        try JSONEncoder().encode(rows).write(to: URL(fileURLWithPath: args[3]), options: .atomic)
        print("Replayed \(rows.count) clips; usable training references \(matcher.usableReferenceCount)/\(bank.references.count)")
    }
}
