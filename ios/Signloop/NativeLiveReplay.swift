#if DEBUG && targetEnvironment(simulator)
import Foundation
import SwiftUI

/// Local simulator research only. Actual native model + app scheduling/filter,
/// prerecorded landmarks and virtual capture clock. Never opens a camera.
struct NativeLiveReplay: View {
    @State private var status = "Replaying offline pipeline…"
    var body: some View {
        VStack(spacing: 20) {
            Text("Signloop · offline pipeline test")
            Text(status).font(.footnote)
            Text("Prerecorded local research. Not live-camera validation.").font(.caption)
        }.padding().task {
            status = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    var report: [String: Any]
                    do { report = try run(folder) }
                    catch { report = ["completed": false, "error_type": String(describing: type(of: error))] }
                    report["run_id"] = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--benchmark-run=") } ?? ""
                    if let data = try? JSONSerialization.data(withJSONObject: report, options: .prettyPrinted) {
                        try? data.write(to: folder.appendingPathComponent("live-replay-result.json"), options: .atomic)
                    }
                    continuation.resume(returning: report["completed"] as? Bool == true ? "Replay complete. Local aggregate report saved." : "Replay failed.")
                }
            }
        }
    }
    private struct Clip: Decodable {
        let split: String
        let label: String
        let frames: [LandmarkFrame]
    }
    private struct Fixture: Decodable { let source: String; let clips: [Clip] }
    private func run(_ folder: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: folder.appendingPathComponent("live-replay-fixture.json"))
        guard data.count <= 25_000_000 else { throw PretrainedSignPolicy.Failure.invalidFrames }
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        guard fixture.source == "LOCAL_RESEARCH_ONLY_ASL_CITIZEN", (1...100).contains(fixture.clips.count) else {
            throw PretrainedSignPolicy.Failure.invalidFrames
        }
        let engine = try PretrainedSignEngine(model: folder.appendingPathComponent("model.tflite"),
                                             vocabulary: folder.appendingPathComponent("sign_to_prediction_index_map.json"))
        var counts: [String: [String: Int]] = [:]
        var durations: [Double] = []
        var modelCalls = 0
        for clip in fixture.clips {
            _ = try PretrainedSignPolicy.pack(clip.frames)
            var policy = LiveWindowPolicy()
            var visible = Set<String>()
            var pending: (LiveWindowPolicy.Job, Classification, Int)?
            func collect() {
                if let sign = policy.visible { visible.insert(sign) }
            }
            for frame in clip.frames {
                if let completion = pending, completion.2 <= frame.timestampMS {
                    policy.complete(completion.0, result: completion.1, nowMS: completion.2)
                    collect()
                    pending = nil
                }
                if let job = policy.ingest(frame, nowMS: frame.timestampMS) {
                    let start = ProcessInfo.processInfo.systemUptime
                    let result = try engine.classify(job.frames)
                    let ms = (ProcessInfo.processInfo.systemUptime-start)*1000
                    durations.append(ms)
                    modelCalls += 1
                    pending = (job, result, frame.timestampMS+max(1, Int(ceil(ms))))
                }
                collect()
            }
            if let completion = pending {
                policy.complete(completion.0, result: completion.1, nowMS: completion.2)
                collect()
            }
            for key in [clip.split, clip.split+"/"+clip.label] {
                var value = counts[key] ?? [:]
                value["clips", default: 0] += 1
                value["correct_display", default: 0] += visible.contains(clip.label) ? 1 : 0
                value["wrong_display", default: 0] += visible.contains(where: { $0 != clip.label }) ? 1 : 0
                value["unknown_only", default: 0] += visible.isEmpty ? 1 : 0
                counts[key] = value
            }
        }
        let sorted = durations.sorted()
        return ["completed": true, "scope": "Previously inspected local research clips, no camera. Actual native classifier and app scheduler; virtual capture timing includes measured simulator inference duration.",
                "counts": counts, "model_calls": modelCalls,
                "mean_inference_ms": durations.reduce(0, +)/Double(max(1, durations.count)),
                "p95_inference_ms": sorted.isEmpty ? 0 : sorted[min(sorted.count-1, Int(Double(sorted.count)*0.95))],
                "model": PretrainedSignPolicy.motionModelName]
    }
}
#endif
