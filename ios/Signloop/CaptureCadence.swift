import Foundation

/// Queue-confined deadline pacing. Measuring each interval from the last
/// admitted 30Hz frame would turn a 24Hz target into a 15Hz half-rate feed.
struct CaptureCadence {
    private let period: Double
    private var deadline: Double?
    private var lastObserved: Double?

    init(targetFPS: Double = 24) {
        precondition(targetFPS.isFinite && targetFPS > 0 && targetFPS <= 120)
        period = 1/targetFPS
    }

    mutating func reset() { deadline = nil; lastObserved = nil }

    mutating func admit(at time: Double) -> Bool {
        guard time.isFinite, time >= 0,
              lastObserved == nil || time > lastObserved! else { return false }
        lastObserved = time
        guard let next = deadline else {
            deadline = time+period
            return true
        }
        guard time+1e-9 >= next else { return false }
        // Preserve the ideal cadence under ordinary camera quantization.
        // After a long stall, restart rather than accumulating catch-up debt.
        deadline = time-next > period ? time+period : next+period
        return true
    }
}
