import Foundation
import Combine

/// Main-thread state, one background match at a time. No camera frames are
/// written, no provider calls, no reference data distributed inside the binary.
final class BasicLiveRecognition: ObservableObject {
    @Published private(set) var sign: String?
    @Published private(set) var detail = "Loading private references…"
    @Published private(set) var ready = false
    @Published private(set) var matchMS = 0
    @Published private(set) var labels: [String] = BasicSignScore.vocabulary
    @Published private(set) var scores = BasicSignScore.rows(labels: BasicSignScore.vocabulary)
    private let worker = DispatchQueue(label: "com.signloop.basic-matching", qos: .userInitiated)
    private var matcher: BasicSignMatcher? // worker only
    private var started = false
    private var busy = false
    private var generation = 0
    private var frames: [SkeletonFrame] = []
    private var lastRequest = -1000
    private var stability = BasicSignStability()
    private let referenceURL: URL

    init(referenceURL: URL? = nil) {
        self.referenceURL = referenceURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("basic-references.json")
    }

    func load() {
        guard !started else { return }
        started = true
        let url = referenceURL
        worker.async {
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size < 40_000_000 else { throw CocoaError(.fileReadCorruptFile) }
                let bank = try JSONDecoder().decode(BasicReferenceBank.self, from: Data(contentsOf: url))
                let model = try BasicSignMatcher(bank: bank)
                guard model.usableReferenceCount > 0 else { throw CocoaError(.fileReadCorruptFile) }
                self.matcher = model
                // Keep private research material out of device cloud backups.
                var referenceURL = url
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try referenceURL.setResourceValues(values)
                DispatchQueue.main.async {
                    self.labels = bank.labels
                    self.clearScores()
                    self.ready = true
                    self.detail = "Sign one word, then relax your hands"
                }
            } catch {
                self.matcher = nil
                DispatchQueue.main.async {
                    self.detail = "Private references unavailable · skeleton still works"
                }
            }
        }
    }

    func reset() {
        generation += 1
        frames.removeAll(keepingCapacity: true)
        lastRequest = -1000
        stability.reset()
        sign = nil
        matchMS = 0
        clearScores()
        if ready { detail = "Sign one word, then relax your hands" }
        // Don't mark an in-flight job free: its completion owns the busy flag.
    }

    private func clearScores() {
        scores = BasicSignScore.rows(labels: labels)
    }

    func receive(_ frame: SkeletonFrame) {
        guard ready else { return }
        if let previous = frames.last,
           frame.timestampMS <= previous.timestampMS || frame.timestampMS-previous.timestampMS > 400 {
            reset()
        }
        frames.append(frame)
        frames.removeAll { $0.timestampMS < frame.timestampMS-2400 }
        if frames.count > 60 { frames.removeFirst(frames.count-60) }
        if frame.hands.isEmpty || !frame.hasPose {
            sign = nil
            clearScores()
            stability.reset()
            generation += 1 // reject any older result returning after hand loss
            detail = "Keep your hands and shoulders in view"
            return
        }
        guard !busy, frame.timestampMS-lastRequest >= 100 else { return }
        busy = true
        lastRequest = frame.timestampMS
        let snapshot = frames
        let token = generation
        let started = ProcessInfo.processInfo.systemUptime
        worker.async {
            let candidate = self.matcher?.candidate(snapshot) ?? BasicCandidate()
            let accepted = self.matcher?.accepted(candidate)
            DispatchQueue.main.async {
                let elapsed = ProcessInfo.processInfo.systemUptime-started
                self.busy = false
                guard token == self.generation else { return }
                guard elapsed < 0.6 else {
                    self.sign = nil
                    self.clearScores()
                    self.stability.reset()
                    self.detail = "Matching delayed · try again"
                    return
                }
                self.matchMS = Int(elapsed*1000)
                self.scores = candidate.scores
                self.sign = self.stability.update(accepted)
                self.detail = self.sign != nil ? "Experimental match · not a translation"
                    : accepted != nil ? "Checking movement…" : "Unknown · try one supported sign"
            }
        }
    }

    static func display(_ label: String) -> String {
        label == "THANKYOU" ? "Thank you" : label.capitalized
    }
}
