import Foundation
import Combine
import QuartzCore

/// Main-thread presentation + one serial model worker. No network or recordings.
/// Private debug assets are provisioned separately while weight rights are
/// clarified; never silently download weights or embed provider credentials.
final class LocalSignRecognition: ObservableObject {
    @Published private(set) var available = false
    @Published private(set) var currentSign: String?
    @Published private(set) var latencyMS = 0
    @Published private(set) var modelStatus = "ILY preview"
    @Published private(set) var inferenceFailed = false
    private let worker = DispatchQueue(label: "com.signloop.local-sign", qos: .userInitiated)
    // Only worker accesses this engine, including initialization.
    private var engine: PretrainedSignEngine?
    private var policy = LiveWindowPolicy()
    private var configured = false
    private var running = false

    private static var nowMS: Int { Int(CaptureClock.now*1000) }

    func prepare() {
        guard !configured else { return }
        configured = true
        #if DEBUG
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let model = documents.appendingPathComponent("model.tflite")
        let vocabulary = documents.appendingPathComponent("sign_to_prediction_index_map.json")
        guard FileManager.default.fileExists(atPath: model.path) ||
                FileManager.default.fileExists(atPath: vocabulary.path) else { return }
        modelStatus = "Loading offline signs…"
        worker.async { [weak self] in
            guard let self else { return }
            do {
                let engine = try PretrainedSignEngine(model: model, vocabulary: vocabulary)
                self.engine = engine
                DispatchQueue.main.async {
                    self.available = true
                    self.modelStatus = "Five-sign research preview"
                    self.reset()
                }
            } catch {
                DispatchQueue.main.async {
                    self.modelStatus = "Sign model unavailable · ILY preview"
                }
            }
        }
        #endif
    }

    func setRunning(_ value: Bool) {
        running = value
        reset()
    }

    func reset() {
        policy.reset()
        currentSign = nil
        latencyMS = 0
        inferenceFailed = false
    }

    func expire() {
        policy.expire(nowMS: Self.nowMS)
        currentSign = policy.visible
    }

    func receive(_ frame: LandmarkFrame) {
        guard available, running else { return }
        let job = policy.ingest(frame, nowMS: Self.nowMS)
        currentSign = policy.visible
        guard let job else { return }
        worker.async { [weak self] in
            guard let self else { return }
            let start = CACurrentMediaTime()
            let result = try? self.engine?.classify(job.frames)
            let elapsed = Int((CACurrentMediaTime()-start)*1000)
            DispatchQueue.main.async {
                if self.policy.complete(job, result: result, nowMS: Self.nowMS) {
                    self.currentSign = self.policy.visible
                    self.latencyMS = elapsed
                    self.inferenceFailed = result == nil
                    self.modelStatus = result == nil ? "Sign inference failed · retrying" : "Five-sign research preview"
                }
            }
        }
    }
}
