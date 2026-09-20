#if DEBUG
import Foundation
import MediaPipeTasksVision
import SwiftUI
import UIKit

/// Explicit developer launch flag only. No camera, network, or asset download.
/// Research landmark fixtures are allowed only on the local Mac simulator.
struct NativePretrainedBenchmark: View {
    @State private var status = "Running native model parity…"
    var body: some View {
        VStack(spacing: 20) {
            Text("Honk & Tell · model research benchmark").font(.headline)
            Text(status).font(.system(.footnote, design: .monospaced))
            Text("No live camera or uploads. This screen is not a sign-recognition demo.")
                .font(.footnote).foregroundStyle(.secondary)
        }.padding().task {
            status = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try run()) }
                    catch {
                        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        let failure: [String: Any] = [
                            "passed": false,
                            "completed_at": ISO8601DateFormatter().string(from: Date()),
                            "run_id": ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--benchmark-run=") } ?? "",
                            "error_type": String(describing: type(of: error))
                        ]
                        if let data = try? JSONSerialization.data(withJSONObject: failure) {
                            try? data.write(to: folder.appendingPathComponent("pretrained-benchmark-result.json"),
                                            options: .atomic)
                        }
                        continuation.resume(returning: "Benchmark failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private struct Query: Decodable {
        let frames: [LandmarkFrame]
        let logits: [Float]?
        let unknown: Bool
        let acceptedLabel: String?
    }
    private struct Fixture: Decodable {
        let source: String
        let queries: [Query]
    }
    private func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: message, code: 1) }
    }

    private func run() throws -> String {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fixtureData = try Data(contentsOf: folder.appendingPathComponent("pretrained-fixture.json"))
        try require(fixtureData.count <= 25_000_000, "Fixture exceeds local test limit")
        let fixture = try JSONDecoder().decode(Fixture.self, from: fixtureData)
        try require(!fixture.queries.isEmpty && fixture.queries.count <= 256, "Invalid query count")
        #if targetEnvironment(simulator)
        let platform = "local Mac iOS simulator"
        #else
        let platform = "physical iPhone"
        try require(fixture.source == "SYNTHETIC_GEOMETRY_NOT_ASL",
                    "Restricted research observations must not be provisioned to the phone")
        #endif
        let start = ProcessInfo.processInfo.systemUptime
        let engine = try PretrainedSignEngine(model: folder.appendingPathComponent("model.tflite"),
                                             vocabulary: folder.appendingPathComponent("sign_to_prediction_index_map.json"))
        let loadMS = (ProcessInfo.processInfo.systemUptime-start)*1000
        // Exercise both users of the shared runtime while the learned model is
        // alive. Public Google thumb-up test image only; never a live camera.
        guard let image = UIImage(contentsOfFile: folder.appendingPathComponent("gesture-benchmark.jpg").path),
              let handModel = Bundle.main.path(forResource: "gesture_recognizer", ofType: "task") else {
            throw NSError(domain: "Provision the public gesture-benchmark.jpg fixture", code: 1)
        }
        let options = GestureRecognizerOptions()
        options.baseOptions.modelAssetPath = handModel
        options.runningMode = .video
        options.numHands = 2
        let handTracker = try GestureRecognizer(options: options)
        let handImage = try MPImage(uiImage: image)
        if let warmup = fixture.queries.first(where: { $0.logits != nil }) {
            for _ in 0..<3 { _ = try engine.logits(warmup.frames) }
        }
        var timings: [Double] = []
        var maxError = 0.0
        var handModelFrames = 0
        for (index, query) in fixture.queries.enumerated() {
            if index % 20 == 0 {
                let hands = try handTracker.recognize(videoFrame: handImage, timestampInMilliseconds: 1000+index*66)
                try require(hands.landmarks.contains(where: { $0.count == 21 }),
                            "MediaPipe/learned-model coexistence failed")
                handModelFrames += 1
            }
            let begin = ProcessInfo.processInfo.systemUptime
            let actual = try engine.logits(query.frames)
            let elapsed = (ProcessInfo.processInfo.systemUptime-begin)*1000
            try require((actual == nil) == (query.logits == nil), "Input-gate parity mismatch")
            guard let actual, let expected = query.logits else {
                try require(query.unknown && query.acceptedLabel == nil, "Rejected fixture has a label")
                continue
            }
            try require(expected.count == 250, "Invalid reference logits")
            for (a, b) in zip(actual, expected) { maxError = max(maxError, abs(Double(a)-Double(b))) }
            try require(maxError <= 0.001, "Native/LiteRT logits differ beyond 0.001")
            let decision = try engine.policy.decode(actual)
            try require(decision.unknown == query.unknown, "Native rejection parity mismatch")
            try require((decision.unknown ? nil : decision.candidates.first?.label) == query.acceptedLabel,
                        "Native label parity mismatch")
            timings.append(elapsed)
        }
        let sorted = timings.sorted()
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count-1, Int(ceil(Double(sorted.count)*0.95))-1)]
        let report: [String: Any] = [
            "passed": true, "completed_at": ISO8601DateFormatter().string(from: Date()),
            "run_id": ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--benchmark-run=") } ?? "",
            "platform": platform, "source": fixture.source, "runtime_version": engine.runtimeVersion,
            "scope": "Native model parity/compute only; NOT live-camera latency or ASL accuracy",
            "queries": fixture.queries.count, "model_calls": timings.count, "warmup_calls": 3,
            "interleaved_hand_model_frames": handModelFrames,
            "max_absolute_logit_error": maxError, "load_ms": loadMS,
            "mean_ms": timings.reduce(0, +)/Double(max(1, timings.count)), "p95_ms": p95
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appendingPathComponent("pretrained-benchmark-result.json"), options: .atomic)
        return String(data: data, encoding: .utf8) ?? "Done"
    }
}
#endif
