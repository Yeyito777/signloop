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
            let emotion = sample.snapshot.status == .active || sample.snapshot.status == .holding
                ? sample.snapshot.emotion : .neutral
            durations[emotion, default: 0] += duration
        }
        // Neutral/unknown time counts against a match. Mixed expressions and ties
        // abstain; returning to rest briefly at the end need not erase the sign's expression.
        return TaughtExpressionLabel.allCases.first {
            $0 != .neutral && durations[$0, default: 0] > (end - start) / 2
        } ?? .neutral
    }
}

/// Conversation matching from MediaPipe blendshapes. No Expression lab and no
/// 2s frozen rest-face: a smile is Joy as soon as the mouth-smile channels rise.
struct LiveExpressionMatcher {
    static let holdMS = 80
    private var rest: [TaughtExpressionLabel: Double] = [:]
    private var pending: TaughtExpressionLabel?
    private var pendingSinceMS: Int?
    private var active: TaughtExpressionLabel?
    private var lastMS: Int?
    private(set) var snapshot = GooseExpressionSnapshot(status: .noFace)

    var title: String {
        switch snapshot.status {
        case .active: return snapshot.emotion.title
        case .holding: return "Hold \(snapshot.emotion.title.lowercased())…"
        case .neutral: return "Relaxed face"
        case .noFace: return "No face"
        case .unavailable: return "Signal unavailable"
        default: return snapshot.status.rawValue
        }
    }

    mutating func reset() {
        rest.removeAll(keepingCapacity: true)
        pending = nil
        pendingSinceMS = nil
        active = nil
        lastMS = nil
        snapshot = GooseExpressionSnapshot(status: .noFace)
    }

    mutating func observe(_ frame: SkeletonFrame) {
        guard frame.hasFace, frame.timestampMS >= 0 else {
            pending = nil; pendingSinceMS = nil; active = nil; lastMS = nil
            snapshot = GooseExpressionSnapshot(status: .noFace)
            return
        }
        if let lastMS, frame.timestampMS < lastMS { reset(); return }
        lastMS = frame.timestampMS
        let smile = Self.blend(frame, "mouthSmile")
        let browDown = Self.blend(frame, "browDown")
        let jaw = Self.blend(frame, "jawOpen")
        let inner = Self.blend(frame, "browInnerUp")
        let sneer = Self.blend(frame, "noseSneer")
        guard smile != nil || browDown != nil || jaw != nil || inner != nil || sneer != nil else {
            pending = nil; pendingSinceMS = nil; active = nil
            snapshot = GooseExpressionSnapshot(status: .unavailable)
            return
        }
        var hits: [(TaughtExpressionLabel, Double)] = []
        if let smile, Self.triggered(smile, rest: rest[.joy], active: active == .joy, floor: 0.18, held: 0.10, delta: 0.10) {
            hits.append((.joy, smile))
        }
        // A smile owns the face. Other cues only fire on a relaxed mouth.
        if hits.isEmpty {
            if let browDown, Self.triggered(browDown, rest: rest[.anger], active: active == .anger, floor: 0.16, held: 0.08, delta: 0.08) {
                hits.append((.anger, browDown))
            }
            if let jaw, Self.triggered(jaw, rest: rest[.fear], active: active == .fear, floor: 0.20, held: 0.12, delta: 0.10) {
                hits.append((.fear, jaw))
            }
            if let inner, Self.triggered(inner, rest: rest[.sadness], active: active == .sadness, floor: 0.42, held: 0.28, delta: 0.14) {
                hits.append((.sadness, inner))
            }
            if let sneer, Self.triggered(sneer, rest: rest[.disgust], active: active == .disgust, floor: 0.18, held: 0.10, delta: 0.10) {
                hits.append((.disgust, sneer))
            }
        }
        if hits.count != 1 {
            if hits.isEmpty {
                Self.assign(&rest, .joy, smile)
                Self.assign(&rest, .anger, browDown)
                Self.assign(&rest, .fear, jaw)
                Self.assign(&rest, .sadness, inner)
                Self.assign(&rest, .disgust, sneer)
            }
            pending = nil; pendingSinceMS = nil; active = nil
            snapshot = GooseExpressionSnapshot(status: hits.isEmpty ? .neutral : .ambiguous)
            return
        }
        let cue = hits[0].0
        if active == cue {
            snapshot = GooseExpressionSnapshot(status: .active, emotion: cue)
            return
        }
        active = nil
        if pending != cue { pending = cue; pendingSinceMS = frame.timestampMS }
        if frame.timestampMS - (pendingSinceMS ?? frame.timestampMS) >= Self.holdMS {
            active = cue; pending = nil; pendingSinceMS = nil
            snapshot = GooseExpressionSnapshot(status: .active, emotion: cue)
        } else {
            snapshot = GooseExpressionSnapshot(status: .holding, emotion: cue)
        }
    }

    private static func blend(_ frame: SkeletonFrame, _ name: String) -> Double? {
        let left = frame.expressions[name + "Left"], right = frame.expressions[name + "Right"]
        if let left, let right, left.isFinite, right.isFinite { return (Double(left) + Double(right)) / 2 }
        guard let value = frame.expressions[name], value.isFinite else { return nil }
        return Double(value)
    }

    private static func triggered(_ value: Double, rest: Double?, active: Bool, floor: Double, held: Double, delta: Double) -> Bool {
        if active { return value >= held }
        if let rest { return value >= max(floor, rest + delta) }
        return value >= floor
    }

    private static func assign(_ rest: inout [TaughtExpressionLabel: Double], _ label: TaughtExpressionLabel, _ value: Double?) {
        guard let value else { return }
        rest[label] = rest[label].map { $0 + 0.2 * (value - $0) } ?? value
    }
}

struct GooseExpressionTracker {
    private var taught: TaughtExpressionRuntime?
    private var live: LiveExpressionMatcher?
    private let setupFailure: GooseExpressionStatus?
    private(set) var snapshot: GooseExpressionSnapshot
    private(set) var history = GooseExpressionHistory()

    var title: String {
        if let setupFailure { return setupFailure.rawValue }
        if let taught { return taught.result.title }
        return live?.title ?? "Relaxed face"
    }

    init(source: GooseExpressionProfile, modelAvailable: Bool) {
        if !modelAvailable {
            taught = nil
            live = nil
            setupFailure = .modelMissing
            snapshot = GooseExpressionSnapshot(status: .modelMissing)
            return
        }
        setupFailure = nil
        if let profile = source.profile {
            taught = TaughtExpressionRuntime(profile: profile)
            live = nil
        } else {
            taught = nil
            live = LiveExpressionMatcher()
        }
        snapshot = GooseExpressionSnapshot(status: .noFace)
    }

    mutating func reset() {
        taught?.resetTracking()
        live?.reset()
        history.reset()
        snapshot = GooseExpressionSnapshot(status: setupFailure ?? .noFace)
    }

    mutating func observe(_ frame: SkeletonFrame) {
        if let setupFailure {
            snapshot = GooseExpressionSnapshot(status: setupFailure)
            history.append(snapshot, at: frame.timestampMS)
            return
        }
        if var runtime = taught {
            runtime.observe(timestampMS: frame.timestampMS, hasFace: frame.hasFace,
                observation: ExpressionObservation.from(frame, measurement: runtime.profile?.measurement ?? .current))
            taught = runtime
            snapshot = Self.snapshot(runtime.result)
        } else if var matcher = live {
            matcher.observe(frame)
            live = matcher
            snapshot = matcher.snapshot
        }
        history.append(snapshot, at: frame.timestampMS)
    }

    private static func snapshot(_ result: TaughtExpressionRuntime.Result) -> GooseExpressionSnapshot {
        switch result {
        case .active(let label): return GooseExpressionSnapshot(status: .active, emotion: label)
        case .neutral: return GooseExpressionSnapshot(status: .neutral)
        case .holding(let label): return GooseExpressionSnapshot(status: .holding, emotion: label)
        case .noFace: return GooseExpressionSnapshot(status: .noFace)
        case .noProfile: return GooseExpressionSnapshot(status: .noProfile)
        case .unavailable: return GooseExpressionSnapshot(status: .unavailable)
        case .wrongCamera: return GooseExpressionSnapshot(status: .wrongCamera)
        case .faceForward: return GooseExpressionSnapshot(status: .faceForward)
        case .unknown: return GooseExpressionSnapshot(status: .unknown)
        case .ambiguous: return GooseExpressionSnapshot(status: .ambiguous)
        }
    }
}
