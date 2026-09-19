import Foundation

/// Main-thread owned scheduling/state, separated from SDKs for deterministic tests.
/// All clock values are monotonic milliseconds. One outstanding job, no backlog.
struct LiveWindowPolicy {
    struct Job {
        let id: Int
        let generation: Int
        let frames: [LandmarkFrame]
        var timestampMS: Int { frames.last!.timestampMS }
    }
    private var generation = 0
    private var sequence = 0
    private var busy: Int?
    private var frames: [LandmarkFrame] = []
    private var lastRequested: Int?
    private var lastResult: Int?
    private var filter = LiveSignFilter()
    private(set) var visible: String?
    var isBusy: Bool { busy != nil }
    var bufferedCount: Int { frames.count }

    mutating func reset() {
        generation += 1
        frames = []
        lastRequested = nil
        lastResult = nil
        filter.reset()
        visible = nil
        // Keep the outstanding slot occupied until its callback. Reset must
        // not enqueue a second invocation behind a slow/cancelled old one.
    }

    mutating func expire(nowMS: Int) {
        if let last = frames.last, nowMS-last.timestampMS > 400 { reset() }
        else if let lastResult, nowMS-lastResult > 400 {
            filter.reset()
            visible = nil
            self.lastResult = nil
        }
    }

    mutating func ingest(_ frame: LandmarkFrame, nowMS: Int) -> Job? {
        guard nowMS >= frame.timestampMS, nowMS-frame.timestampMS <= 400,
              !frame.hands.isEmpty else { reset(); return nil }
        if let last = frames.last {
            if frame.timestampMS <= last.timestampMS {
                // A duplicated/out-of-order callback cannot confirm a sign.
                reset()
                return nil
            }
            if frame.timestampMS-last.timestampMS > 200 ||
                frame.mirrored != last.mirrored || frame.imageAspectRatio != last.imageAspectRatio {
                reset()
            }
        }
        frames.append(frame)
        frames.removeAll { $0.timestampMS < frame.timestampMS-1200 }
        if frames.count > 90 { frames.removeFirst(frames.count-90) }
        expire(nowMS: nowMS)
        guard busy == nil, lastRequested == nil || nowMS-lastRequested! >= 250 else { return nil }
        let sampled = Self.resample(frames)
        guard sampled.count >= 6 else { return nil }
        sequence += 1
        busy = sequence
        lastRequested = nowMS
        return Job(id: sequence, generation: generation, frames: sampled)
    }

    /// Select actual observed frames nearest a 15Hz grid ending at the newest
    /// observation. No interpolated joints, duplicate observations or future
    /// frames. Temporal windows match research cadence rather than camera FPS.
    static func resample(_ frames: [LandmarkFrame]) -> [LandmarkFrame] {
        guard let first = frames.first, let end = frames.last else { return [] }
        var chosen = Set<Int>()
        var target = Double(end.timestampMS)
        while target >= Double(first.timestampMS) {
            let index = frames.indices.min {
                let a = abs(Double(frames[$0].timestampMS)-target)
                let b = abs(Double(frames[$1].timestampMS)-target)
                return a == b ? $0 < $1 : a < b
            }!
            chosen.insert(index)
            target -= 1000.0/15.0
        }
        return chosen.sorted().map { frames[$0] }
    }

    /// Returns false for superseded/stale callbacks. Even a stale job releases
    /// its own busy slot, but cannot update the new camera generation.
    @discardableResult
    mutating func complete(_ job: Job, result: Classification?, nowMS: Int) -> Bool {
        guard busy == job.id else { return false }
        busy = nil
        guard job.generation == generation else { return false }
        guard nowMS >= job.timestampMS, nowMS-job.timestampMS <= 400,
              let latest = frames.last, nowMS-latest.timestampMS <= 400 else {
            filter.reset(); visible = nil; lastResult = nil
            return false
        }
        let allowed = ["HELLO", "YES", "NO", "PLEASE", "THANK_YOU"]
        let candidate = result?.candidates.first
        let label = result?.unknown == false && candidate?.score.isFinite == true &&
            candidate.map({ allowed.contains($0.label) && (0...1).contains($0.score) }) == true ? candidate?.label : nil
        visible = filter.update(label)
        lastResult = job.timestampMS
        return true
    }
}
