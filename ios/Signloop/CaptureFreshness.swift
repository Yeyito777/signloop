import Foundation
import CoreMedia

/// Use one explicit host clock for capture PTS, UI expiry and model policy.
enum CaptureClock {
    static var now: Double { CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) }

    static func hostSeconds(presentation: CMTime, sourceClock: CMClock?) -> Double? {
        guard presentation.isNumeric, let sourceClock else { return nil }
        let converted = CMSyncConvertTime(presentation, from: sourceClock,
                                          to: CMClockGetHostTimeClock())
        guard converted.isNumeric else { return nil }
        let seconds = CMTimeGetSeconds(converted)
        return seconds.isFinite ? seconds : nil
    }
}

/// Camera-queue-only admission. Never "repair" stale, future or duplicate
/// observations by stamping them with processing time.
struct CaptureFreshness {
    private var epoch = Double.infinity
    private var previous: Double?
    private var previousMS: Int?

    static func isFresh(captured: Double, now: Double) -> Bool {
        captured.isFinite && now.isFinite && captured >= 0 &&
            captured <= now && now-captured <= 0.4
    }

    mutating func reset(at time: Double) {
        epoch = time.isFinite && time >= 0 ? time : .infinity
        previous = nil
        previousMS = nil
    }

    mutating func timestamp(captured: Double, now: Double) -> Int? {
        guard Self.isFresh(captured: captured, now: now), captured >= epoch,
              captured < Double(Int.max / 1000),
              previous == nil || captured > previous! else { return nil }
        let milliseconds = Int(captured*1000)
        guard previousMS == nil || milliseconds > previousMS! else { return nil }
        previous = captured
        previousMS = milliseconds
        return milliseconds
    }
}

/// Main-thread watchdog state. Expiry is a one-shot invalidation, not a reset
/// on every timer tick that could repeatedly cancel a recovering worker.
struct CaptureDisplayLifetime {
    private var captured: Double?

    mutating func received(at time: Double) { captured = time }
    mutating func reset() { captured = nil }

    mutating func expire(now: Double) -> Bool {
        guard let captured else { return false }
        guard !CaptureFreshness.isFresh(captured: captured, now: now) else { return false }
        self.captured = nil
        return true
    }
}
