#if DEBUG
import Foundation
import MediaPipeTasksVision
import SwiftUI
import UIKit

/// Explicit developer launch flag only. Does not open a camera or a network
/// connection. Reads a deliberately provisioned test image, writes metrics only.
struct NativeGestureBenchmark: View {
    @State private var status = "Running on-device model benchmark…"
    var body: some View {
        VStack(spacing: 20) {
            Text("Signloop · developer benchmark").font(.headline)
            Text(status).font(.system(.footnote, design: .monospaced))
            Text("No live camera, recording or uploads. Reopen normally to use the app.")
                .font(.footnote).foregroundStyle(.secondary)
        }.padding(24).task {
            let message: String = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try run()) }
                    catch { continuation.resume(returning: "Benchmark failed: \(error.localizedDescription)") }
                }
            }
            status = message
        }
    }

    private func run() throws -> String {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let input = folder.appendingPathComponent("gesture-benchmark.jpg")
        guard let image = UIImage(contentsOfFile: input.path),
              let model = Bundle.main.path(forResource: "gesture_recognizer", ofType: "task") else {
            throw NSError(domain: "Provision gesture-benchmark.jpg and the pinned model first", code: 1)
        }
        let options = GestureRecognizerOptions()
        options.baseOptions.modelAssetPath = model
        options.runningMode = .video
        options.numHands = 2
        options.minHandDetectionConfidence = 0.55
        options.minHandPresenceConfidence = 0.55
        options.minTrackingConfidence = 0.55
        let classifier = ClassifierOptions()
        classifier.maxResults = 2
        options.cannedGesturesClassifierOptions = classifier
        let loadStart = CACurrentMediaTime()
        let recognizer = try GestureRecognizer(options: options)
        let loadMS = (CACurrentMediaTime() - loadStart) * 1000
        let frame = try MPImage(uiImage: image)
        var samples: [Double] = []
        var handFrames = 0
        var localAccepts = 0
        var filter = LocalGestureFilter()
        for index in 0..<35 {
            let start = CACurrentMediaTime()
            let result = try recognizer.recognize(videoFrame: frame, timestampInMilliseconds: index * 66)
            let elapsed = (CACurrentMediaTime() - start) * 1000
            if index >= 5 { samples.append(elapsed) }
            if !result.landmarks.isEmpty { handFrames += 1 }
            let hands = result.gestures.map { categories -> LocalHandGesture in
                let ranked = categories.sorted { $0.score > $1.score }
                return LocalHandGesture(label: ranked.first?.categoryName ?? "None",
                                        score: ranked.first?.score ?? 0,
                                        runner: ranked.dropFirst().first?.score ?? 0)
            }
            if filter.update(hands, timestampMS: index * 66) != nil { localAccepts += 1 }
        }
        let sorted = samples.sorted()
        let report: [String: Any] = [
            "completed_at": ISO8601DateFormatter().string(from: Date()),
            "run_id": ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--benchmark-run=") }) ?? "",
            "scope": "Repeated provisioned static test image; not live signing or camera-to-display latency",
            "model": "MediaPipe Gesture Recognizer float16 v1 / Tasks 0.10.21",
            "device": UIDevice.current.model, "os": UIDevice.current.systemVersion,
            "measured_frames": samples.count, "warmup_frames": 5, "load_ms": loadMS,
            "mean_ms": samples.reduce(0, +) / Double(samples.count),
            "median_ms": sorted[sorted.count / 2], "p95_ms": sorted[Int(Double(sorted.count - 1) * 0.95)],
            "frames_with_hands": handFrames, "local_ily_accepted_frames": localAccepts
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appendingPathComponent("gesture-benchmark-result.json"), options: .atomic)
        return String(data: data, encoding: .utf8) ?? "Done"
    }
}
#endif
