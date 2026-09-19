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

    mutating func reset(at time: Double) {
        epoch = time.isFinite && time >= 0 ? time : .infinity
        previous = nil
        previousMS = nil
    }

    mutating func timestamp(captured: Double, now: Double) -> Int? {
        guard captured.isFinite, now.isFinite, captured >= epoch,
              captured >= 0, captured <= now, now-captured <= 0.4,
              captured < Double(Int.max / 1000),
              previous == nil || captured > previous! else { return nil }
        let milliseconds = Int(captured*1000)
        guard previousMS == nil || milliseconds > previousMS! else { return nil }
        previous = captured
        previousMS = milliseconds
        return milliseconds
    }
}
