import Foundation
import CoreMedia

@main
struct CaptureFreshnessTests {
    static func check(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }

    static func main() {
        var gate = CaptureFreshness()
        check(gate.timestamp(captured: 10, now: 10) == nil, "Unstarted capture admitted")
        gate.reset(at: 10)
        check(gate.timestamp(captured: 9.99, now: 10.1) == nil, "Pre-switch queued frame admitted")
        check(gate.timestamp(captured: 10, now: 10.25) == 10_000, "Capture time replaced by delivery time")
        check(gate.timestamp(captured: 10, now: 10.26) == nil, "Duplicate timestamp admitted")
        check(gate.timestamp(captured: 10.0001, now: 10.26) == nil, "Same model millisecond repaired")
        check(gate.timestamp(captured: 9.9, now: 10.26) == nil, "Reordered frame admitted")
        check(gate.timestamp(captured: 10.1, now: 10.501) == nil, "Old frame became fresh")
        check(gate.timestamp(captured: 11, now: 10.6) == nil, "Future frame admitted")
        check(gate.timestamp(captured: 10.3, now: 10.6) == 10_300, "Bad input poisoned valid recovery")
        for bad in [Double.nan, .infinity, -.infinity, -1, Double.greatestFiniteMagnitude] {
            check(gate.timestamp(captured: bad, now: bad) == nil, "Invalid time admitted")
        }
        gate.reset(at: 20)
        check(gate.timestamp(captured: 19.99, now: 20.1) == nil, "Reset retained prior-camera frames")
        check(gate.timestamp(captured: 20.03, now: 20.05) == 20_030, "Fresh switched camera blocked")
        gate.reset(at: .nan)
        check(gate.timestamp(captured: 21, now: 21) == nil, "Invalid epoch enabled capture")
        print("PASS: capture age, epochs, duplicate/invalid/future rejection, recovery")

        var display = CaptureDisplayLifetime()
        check(!display.expire(now: 0), "Empty display invalidated")
        display.received(at: 0)
        check(!display.expire(now: 0.4), "Fresh boundary expired")
        check(display.expire(now: 0.401), "Stalled display remained visible")
        check(!display.expire(now: 0.8), "Expiry repeatedly cancelled recovering worker")
        display.received(at: 1)
        check(!display.expire(now: 1.1), "New frame did not recover display")
        display.reset()
        check(!display.expire(now: 2), "Pause reset retained observation")
        for invalid in [Double.nan, .infinity, -.infinity, -1] {
            display.received(at: 1)
            check(display.expire(now: invalid), "Invalid/future presentation clock retained display")
        }
        // The app's 250ms timer must expire within 650ms of capture even when
        // the camera delivers no further callback at all.
        for phase in stride(from: 0.0, to: 0.25, by: 0.01) {
            display.received(at: 10)
            var expiredAt: Double?
            for i in 0..<4 {
                let now = 10+phase+Double(i)*0.25
                if display.expire(now: now) { expiredAt = now }
            }
            check(expiredAt != nil && expiredAt! <= 10.65,
                  "Timer phase left stale geometry visible")
        }
        print("PASS: one-shot overlay expiry, recovery, pause reset and timer-phase bounds")

        let host = CMClockGetHostTimeClock()
        let pts = CMClockGetTime(host)
        let converted = CaptureClock.hostSeconds(presentation: pts, sourceClock: host)
        check(converted != nil && abs(converted! - CMTimeGetSeconds(pts)) < 1e-6,
              "CoreMedia host conversion changed timestamp")
        check(CaptureClock.hostSeconds(presentation: .invalid, sourceClock: host) == nil,
              "Invalid CMTime accepted")
        check(CaptureClock.hostSeconds(presentation: .indefinite, sourceClock: host) == nil,
              "Indefinite CMTime accepted")
        check(CaptureClock.hostSeconds(presentation: pts, sourceClock: nil) == nil,
              "Missing session clock invented host time")
        check(CaptureClock.now >= converted!, "Clock helper regressed")
        print("PASS: actual CoreMedia clock conversion and invalid/missing clock rejection")

        // Delivery jitter must not change capture cadence or temporal geometry.
        var cadence = CaptureCadence()
        gate.reset(at: 100)
        var accepted = 0
        for i in 0..<1800 {
            let captured = 100+Double(i)/30
            let delay = Double((i*37)%80)/1000
            guard gate.timestamp(captured: captured, now: captured+delay) != nil else {
                fatalError("Fresh delayed sample rejected")
            }
            if cadence.admit(at: captured) { accepted += 1 }
        }
        check(accepted == 1440, "Delivery jitter distorted capture cadence")
        print("PASS: 60s capture-time pacing remains 24Hz despite 0–79ms delivery jitter")
    }
}
