#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import MediaPipeTasksVision
import CryptoKit

/// Simulator-only smoke test of the actual shipping detector pipeline.
/// Accepts only hash-pinned public MediaPipe test assets, never a camera feed.
struct NativeSkeletonBenchmark: View {
    @State private var status = "Running tracking smoke test…"
    var body: some View {
        ScrollView {
            Text(status).font(.system(.footnote, design: .monospaced)).padding()
        }.task {
            status = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    var report: [String: Any]
                    do { report = try run(folder) }
                    catch { report = ["completed": false, "error": error.localizedDescription] }
                    report["run_id"] = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--benchmark-run=") } ?? ""
                    do {
                        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                        try data.write(to: folder.appendingPathComponent("skeleton-benchmark-result.json"), options: .atomic)
                        continuation.resume(returning: String(decoding: data, as: UTF8.self))
                    } catch { continuation.resume(returning: error.localizedDescription) }
                }
            }
        }
    }

    private func run(_ folder: URL) throws -> [String: Any] {
        func require(_ condition: Bool, _ text: String) throws {
            if !condition { throw NSError(domain: "Skeleton benchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
        }
        let assets = [
            ("pose.jpg", "c8a830ed683c0276d713dd5aeda28f415f10cd6291972084a40d0d8b934ed62b"),
            ("portrait.jpg", "a6f11efaa834706db23f275b6115058fa87fc7f14362681e6abe14e82749de3e"),
            ("thumb_up.jpg", "5d673c081ab13b8a1812269ff57047066f9c33c07db5f4178089e8cb3fdc0291")]
        var results: [[String: Any]] = []
        for trackFace in [false, true] {
        for (name, digest) in assets {
            let data = try Data(contentsOf: folder.appendingPathComponent(name))
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try require(actual == digest, "Fixture hash mismatch: \(name)")
            guard let image = UIImage(data: data) else { throw NSError(domain: "Invalid fixture", code: 1) }
            let pipeline = try SkeletonPipeline(trackFace: trackFace)
            let mpImage = try MPImage(uiImage: image)
            var last: SkeletonFrame?
            var times: [Double] = []
            for i in 0..<15 {
                let frame = try pipeline.detect(mpImage, timestampMS: i*100,
                    width: Int(image.size.width), height: Int(image.size.height), camera: "fixture")
                try require(frame.timestampMS == i*100, "Timestamp mismatch")
                _ = try JSONEncoder().encode(frame) // catches non-finite coefficients/geometry
                if i >= 3 { times.append(frame.timingsMS["total"] ?? 0) }
                last = frame
            }
            guard let frame = last else { throw NSError(domain: "No frames", code: 1) }
            if name == "pose.jpg" { try require(frame.hasPose, "Expected body missing") }
            if name == "portrait.jpg" && trackFace {
                try require(frame.face.count == 478 && frame.expressions.count == 52, "Expected face/blendshapes missing")
                try require(frame.face.allSatisfy(\.usable), "Face points unexpectedly hidden by confidence gate")
            }
            if !trackFace {
                try require(frame.face.isEmpty && frame.expressions.isEmpty && frame.timingsMS["face"] == 0,
                            "Face-disabled mode still produced face data/work")
            }
            if name == "thumb_up.jpg" {
                try require(frame.hands.contains { $0.points.count == 21 && $0.points.allSatisfy(\.usable) }, "Expected drawable hand missing")
            }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let blank = UIGraphicsImageRenderer(size: CGSize(width: 720, height: 1280), format: format).image { c in
                UIColor.black.setFill()
                c.fill(CGRect(x: 0, y: 0, width: 720, height: 1280))
            }
            let blankMP = try MPImage(uiImage: blank)
            // Same pipeline: verify disappearance, not just a new model's empty result.
            for i in 15..<18 {
                last = try pipeline.detect(blankMP, timestampMS: i*100, width: 720, height: 1280, camera: "fixture")
            }
            try require(last?.hands.isEmpty == true && last?.pose.isEmpty == true &&
                        last?.face.isEmpty == true && last?.expressions.isEmpty == true, "Stale result after blank input")
            let sorted = times.sorted()
            results.append(["fixture": name, "track_face": trackFace, "hands": frame.hands.count, "upper_body_points": frame.pose.count,
                "drawable_body_points": frame.pose.filter(\.usable).count,
                "face_points": frame.face.count, "blendshapes": frame.expressions.count,
                "median_ms": sorted[sorted.count/2], "p95_ms": sorted[Int(Double(sorted.count-1)*0.95)],
                "blank_cleared": true])
        }
        }
        return ["completed": true, "scope": "Public static fixtures on simulator; not live phone performance or ASL recognition",
                "fixtures": results]
    }
}
#endif
