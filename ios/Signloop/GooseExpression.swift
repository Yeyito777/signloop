import Foundation

/// Transport states describe matching availability, never a probability of feelings.
enum GooseExpressionStatus: String {
    case active, neutral, holding, unknown, ambiguous, unavailable, stale
    case noFace = "no-face", noProfile = "no-profile", profileInvalid = "profile-invalid"
    case modelMissing = "model-missing", wrongCamera = "wrong-camera", faceForward = "face-forward"
}

struct GooseExpressionSnapshot: Equatable {
    var status: GooseExpressionStatus
    var emotion: TaughtExpressionLabel = .neutral
}

struct GooseExpressionProfile {
    var profile: TaughtExpressionProfile?
    var failure: GooseExpressionStatus?

    /// The newest taught or provisioned local profile overrides the optional bundle.
    /// An invalid replacement is diagnosed rather than silently using another person's profile.
    static func load(localURL: URL, taughtURL: URL? = nil, bundledURL: URL?) -> Self {
        let latestLocal = [localURL, taughtURL].compactMap { $0 }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .max { a, b in
                // Read fresh attributes: URL resource values may cache a pre-save date.
                let aDate = (try? FileManager.default.attributesOfItem(atPath: a.path))?[.modificationDate] as? Date
                let bDate = (try? FileManager.default.attributesOfItem(atPath: b.path))?[.modificationDate] as? Date
                return (aDate ?? .distantPast) < (bDate ?? .distantPast)
            }
        guard var url = latestLocal ?? bundledURL else { return Self(failure: .noProfile) }
        do {
            let profile = try TaughtExpressionStore.read(url)
            if latestLocal != nil {
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                try url.setResourceValues(values)
            }
            return Self(profile: profile)
        } catch { return Self(failure: .profileInvalid) }
    }
}

/// Bounded, RAM-only summaries let a delayed matcher use the expression from
/// its INPUT interval, never the face seen when its background job finishes.
struct GooseExpressionHistory {
    private var samples: [(time: Int, snapshot: GooseExpressionSnapshot)] = []

    mutating func reset() { samples.removeAll(keepingCapacity: true) }

    mutating func append(_ snapshot: GooseExpressionSnapshot, at timestamp: Int) {
        guard timestamp >= 0 else { return }
        if let last = samples.last, timestamp <= last.time || timestamp - last.time > 400 { reset() }
        samples.append((timestamp, snapshot))
        samples.removeAll { $0.time < timestamp - 6500 }
        if samples.count > 512 { samples.removeFirst(samples.count - 512) }
    }

    func emotion(from start: Int, through end: Int) -> TaughtExpressionLabel {
        guard start <= end, let last = samples.last(where: { $0.time <= end }), end - last.time <= 400 else { return .neutral }
        if start == end { return last.snapshot.emotion }
        var durations: [TaughtExpressionLabel: Int] = [:]
        for (index, sample) in samples.enumerated() where sample.time <= end {
            let next = index + 1 < samples.count ? samples[index + 1].time : end
            let duration = max(0, min(end, min(next, sample.time + 400)) - max(start, sample.time))
            let emotion = sample.snapshot.status == .active ? sample.snapshot.emotion : .neutral
            durations[emotion, default: 0] += duration
        }
        // Neutral/unknown time counts against a match. Mixed expressions and ties
        // abstain; returning to rest briefly at the end need not erase the sign's expression.
        return TaughtExpressionLabel.allCases.first {
            $0 != .neutral && durations[$0, default: 0] > (end - start) / 2
        } ?? .neutral
    }
}

struct GooseExpressionTracker {
    private var runtime: TaughtExpressionRuntime
    private let setupFailure: GooseExpressionStatus?
    private(set) var snapshot: GooseExpressionSnapshot
    private(set) var history = GooseExpressionHistory()

    var title: String {
        if let setupFailure { return setupFailure.rawValue }
        return runtime.result.title
    }

    init(source: GooseExpressionProfile, modelAvailable: Bool) {
        runtime = TaughtExpressionRuntime(profile: source.profile)
        setupFailure = modelAvailable ? source.failure : .modelMissing
        snapshot = GooseExpressionSnapshot(status: setupFailure ?? .noFace)
    }

    mutating func reset() {
        runtime.resetTracking(); history.reset()
        snapshot = GooseExpressionSnapshot(status: setupFailure ?? .noFace)
    }

    mutating func observe(_ frame: SkeletonFrame) {
        if let setupFailure {
            snapshot = GooseExpressionSnapshot(status: setupFailure)
        } else {
            runtime.observe(timestampMS: frame.timestampMS, hasFace: frame.hasFace,
                observation: ExpressionObservation.from(frame, measurement: runtime.profile?.measurement ?? .current))
            switch runtime.result {
            case .active(let label): snapshot = GooseExpressionSnapshot(status: .active, emotion: label)
            case .neutral: snapshot = GooseExpressionSnapshot(status: .neutral)
            case .holding: snapshot = GooseExpressionSnapshot(status: .holding)
            case .noFace: snapshot = GooseExpressionSnapshot(status: .noFace)
            case .noProfile: snapshot = GooseExpressionSnapshot(status: .noProfile)
            case .unavailable: snapshot = GooseExpressionSnapshot(status: .unavailable)
            case .wrongCamera: snapshot = GooseExpressionSnapshot(status: .wrongCamera)
            case .faceForward: snapshot = GooseExpressionSnapshot(status: .faceForward)
            case .unknown: snapshot = GooseExpressionSnapshot(status: .unknown)
            case .ambiguous: snapshot = GooseExpressionSnapshot(status: .ambiguous)
            }
        }
        history.append(snapshot, at: frame.timestampMS)
    }
}
