import Foundation

/// Post-benchmark diagnostic: annotated synthetic boundaries isolate matching
/// from automatic segmentation. This oracle is NOT a deployable policy.
@main struct DiagnoseGestureBoundaries {
    struct Row: Codable {
        let id: String, label: String, profile: String, oracleChoices: [String]
        let segments: [Segment]
    }
    struct Segment: Codable {
        let emittedMS: Int, startMS: Int, endMS: Int, choices: [String]
    }
    static func main() throws {
        let (bank, clips) = CompareGesturePolicies.synthetic()
        let matcher = try BasicSignMatcher(bank: bank)
        func rank(_ frames: [SkeletonFrame]) -> [String] {
            matcher.candidate(frames, completed: true).scores.filter { $0.measuredDistance != nil }
                .sorted { $0.distance == $1.distance ? $0.label < $1.label : $0.distance! < $1.distance! }
                .prefix(3).map(\.label)
        }
        var rows: [Row] = []
        for clip in clips {
            // Annotated end comes from the generator; this deliberately grants
            // information that real inference does not have. Do not tune to it.
            let whole = clip.frames.filter { $0.timestampMS <= clip.endMS! }
            var segmenter = BasicSignSegmentation(), segments: [Segment] = []
            for frame in clip.frames {
                if let frames = segmenter.update(frame), let first = frames.first, let last = frames.last {
                    segments.append(Segment(emittedMS: frame.timestampMS, startMS: first.timestampMS,
                        endMS: last.timestampMS, choices: rank(frames)))
                }
            }
            rows.append(Row(id: clip.id, label: clip.label, profile: clip.profile,
                            oracleChoices: rank(whole), segments: segments))
        }
        try JSONEncoder().encode(rows).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("Saved boundary diagnostics for \(rows.count) synthetic clips; oracle boundaries are not a runtime proposal")
    }
}
