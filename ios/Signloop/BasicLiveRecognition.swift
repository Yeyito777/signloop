import Foundation
import Combine

/// A tentative ranking, never a confirmed caption. Timestamp belongs to the
/// last input frame, so consumers cannot mistake completion time for freshness.
struct BasicLivePrediction {
    enum Phase: String { case preview, completed, cleared }
    let label: String?
    let matched: Bool
    let timestampMS: Int?
    var phase: Phase = .preview
    var candidates: [BasicSignScore] = []
    var attemptID: Int? = nil
    var startTimestampMS: Int? = nil

    static func cleared(at timestamp: Int? = nil) -> BasicLivePrediction {
        BasicLivePrediction(label: nil, matched: false, timestampMS: timestamp, phase: .cleared)
    }
}

enum BasicReferenceLoadFailure: String {
    case missing, invalid
}

/// Main-thread state, one background match at a time. No camera frames are
/// written, no provider calls, no reference data distributed inside the binary.
final class BasicLiveRecognition: ObservableObject {
    @Published private(set) var sign: String?
    @Published private(set) var detail = "Loading private references…"
    @Published private(set) var ready = false
    @Published private(set) var loading = false
    @Published private(set) var loadFailure: BasicReferenceLoadFailure?
    @Published private(set) var matchMS = 0
    @Published private(set) var labels: [String] = BasicSignScore.vocabulary
    @Published private(set) var scores = BasicSignScore.rows(labels: BasicSignScore.vocabulary)
    private let worker = DispatchQueue(label: "com.signloop.basic-matching", qos: .userInitiated)
    private var matcher: BasicSignMatcher? // worker only
    var onPrediction: ((BasicLivePrediction) -> Void)? // main thread, fresh results and invalidations
    private var busy = false
    private var generation = 0
    private var frames: [SkeletonFrame] = []
    private var lastRequest = -1000
    private var lastObservedHand: Int?
    private var stability = BasicSignStability()
    private var segmentation = BasicSignSegmentation()
    private var nextAttemptID = 0
    private var currentAttemptID: Int?
    private struct Request {
        let frames: [SkeletonFrame]
        let attemptID: Int
        let completed: Bool
    }
    private var pendingSegments: [Request] = []
    private let referenceURL: URL
    private let activeLabels: [String]?
    private let weMotionScale: Float?

    init(referenceURL: URL? = nil, activeLabels: [String]? = nil, weMotionScale: Float? = nil) {
        self.referenceURL = referenceURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("basic-references.json")
        self.activeLabels = activeLabels
        self.weMotionScale = weMotionScale
        self.labels = activeLabels ?? BasicSignScore.vocabulary
        self.scores = BasicSignScore.rows(labels: self.labels)
    }

    func load() {
        guard !ready, !loading else { return }
        loading = true
        loadFailure = nil
        let url = referenceURL
        worker.async {
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size < 40_000_000 else { throw CocoaError(.fileReadCorruptFile) }
                let source = try JSONDecoder().decode(BasicReferenceBank.self, from: Data(contentsOf: url))
                let bank = try self.activeLabels.map { try source.restricted(to: $0) } ?? source
                let model = try BasicSignMatcher(bank: bank, weMotionScale: self.weMotionScale)
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
                    self.loading = false
                    self.detail = "Sign one word, then relax your hands"
                }
            } catch {
                self.matcher = nil
                let code = (error as NSError).code
                let missing = (error as NSError).domain == NSCocoaErrorDomain &&
                    (code == NSFileReadNoSuchFileError || code == NSFileNoSuchFileError)
                DispatchQueue.main.async {
                    self.loading = false
                    self.loadFailure = missing ? .missing : .invalid
                    self.detail = "Private references unavailable · skeleton still works"
                }
            }
        }
    }

    func reset() {
        generation += 1
        frames.removeAll(keepingCapacity: true)
        lastRequest = -1000
        lastObservedHand = nil
        stability.reset()
        segmentation.reset()
        currentAttemptID = nil
        pendingSegments.removeAll(keepingCapacity: true)
        sign = nil
        matchMS = 0
        clearScores()
        onPrediction?(.cleared())
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
        if let observed = lastObservedHand, frame.timestampMS-observed > 300 {
            reset() // Do not mix a preceding sign into a new hands-in-view episode.
        }
        if !frame.hands.isEmpty && frame.hasSigningPose { lastObservedHand = frame.timestampMS }
        frames.append(frame)
        frames.removeAll { $0.timestampMS < frame.timestampMS-2400 }
        if frames.count > 60 { frames.removeFirst(frames.count-60) }
        if frame.hands.isEmpty || !frame.hasSigningPose {
            reset() // invalidate queued segments and any older worker result
            detail = "Keep your hands and shoulders in view"
            onPrediction?(.cleared(at: frame.timestampMS))
            return
        }
        let completed = segmentation.update(frame)
        if segmentation.startsAttempt || currentAttemptID == nil {
            nextAttemptID += 1
            currentAttemptID = nextAttemptID
        }
        if let completed {
            // Bounded backlog; a stalled worker must never produce old captions.
            guard pendingSegments.count < 4 else {
                reset()
                detail = "Matching delayed · try again"
                return
            }
            pendingSegments.append(Request(frames: completed, attemptID: currentAttemptID!, completed: true))
        }
        if !pendingSegments.isEmpty {
            startNextSegment()
            return
        }
        guard !busy, frame.timestampMS-lastRequest >= 250 else { return }
        start(Request(frames: frames, attemptID: currentAttemptID!, completed: false))
    }

    private func startNextSegment() {
        guard !busy, !pendingSegments.isEmpty else { return }
        start(pendingSegments.removeFirst())
    }

    private func start(_ request: Request) {
        guard let observed = request.frames.last else { return }
        let windowStart = request.completed ? request.frames.first?.timestampMS
            : max(request.frames.first?.timestampMS ?? observed.timestampMS,
                  segmentation.attemptStartMS ?? observed.timestampMS)
        busy = true
        lastRequest = frames.last?.timestampMS ?? observed.timestampMS
        let token = generation
        let started = ProcessInfo.processInfo.systemUptime
        worker.async {
            let completed = request.completed
            let candidate = self.matcher?.candidate(request.frames, completed: completed) ?? BasicCandidate()
            let accepted = self.matcher?.accepted(candidate)
            DispatchQueue.main.async {
                let elapsed = ProcessInfo.processInfo.systemUptime-started
                self.busy = false
                defer { self.startNextSegment() }
                guard token == self.generation else { return }
                guard elapsed < 0.6,
                      (self.frames.last?.timestampMS ?? observed.timestampMS) - observed.timestampMS <= 1000 else {
                    self.sign = nil
                    self.clearScores()
                    self.stability.reset()
                    self.detail = "Matching delayed · try again"
                    self.onPrediction?(.cleared(at: observed.timestampMS))
                    return
                }
                self.matchMS = Int(elapsed*1000)
                self.scores = candidate.scores
                // Ranking is visible even below the rejection threshold. The
                // quality gate now annotates the guess, never hides it.
                if completed { self.stability.reset() }
                let supported = completed ? nil : self.stability.update(accepted)
                self.sign = candidate.label
                self.detail = candidate.label == nil ? "Collecting movement · keep hands visible"
                    : supported != nil ? "Best guess · clearer match, still experimental"
                    : "Best guess · uncertain, not a confirmed sign"
                self.onPrediction?(BasicLivePrediction(label: candidate.label,
                    // The existing acceptance policy was calibrated on rolling
                    // windows, not complete segments. Keep final choices uncertain.
                    matched: !completed && supported != nil, timestampMS: observed.timestampMS,
                    phase: completed ? .completed : .preview,
                    candidates: Array(candidate.scores.filter { $0.measuredDistance != nil }
                        .sorted { a, b in
                            a.distance == b.distance ? a.label < b.label : a.distance! < b.distance!
                        }.prefix(3)), attemptID: request.attemptID, startTimestampMS: windowStart))
            }
        }
    }

    static func display(_ label: String) -> String {
        switch label {
        case "THANKYOU": return "Thank you"
        case "ILOVEYOU": return "I love you"
        case "SIGNLANGUAGE": return "Sign language"
        default: return label.capitalized
        }
    }
}
