import Foundation

@main
struct CaptureCadenceTests {
    static func require(_ value: Bool, _ message: String) {
        if !value { fatalError(message) }
    }
    static func main() {
        for inputFPS in [10, 15, 24, 30, 60, 120] {
            var cadence = CaptureCadence()
            var count = 0
            for i in 0..<(inputFPS*60) {
                if cadence.admit(at: 100+Double(i)/Double(inputFPS)) { count += 1 }
            }
            let expected = min(inputFPS, 24)*60
            require(abs(count-expected) <= 1, "Frame-rate quantization drift at \(inputFPS) FPS: \(count)")
            print("PASS: \(inputFPS)Hz input → \(Double(count)/60)Hz tracking target")
        }

        var oldCount = 0, oldLast = 0.0
        for i in 0..<1800 {
            let now = 100+Double(i)/30
            if now-oldLast >= 1.0/24 { oldCount += 1; oldLast = now }
        }
        require(oldCount == 900, "Regression fixture no longer reproduces old half-rate bug")
        print("PASS: old limiter regression reproduced: 900/1800 frames (15Hz)")

        var jitter = CaptureCadence()
        var accepted: [Double] = []
        for i in 0..<1800 {
            let noise = Double((i*37)%11-5)*0.0006 // deterministic ±3ms, no reordered frames
            let now = 100+Double(i)/30+noise
            if jitter.admit(at: now) { accepted.append(now) }
        }
        require((1438...1442).contains(accepted.count), "Normal delivery jitter lost cadence")
        require(zip(accepted, accepted.dropFirst()).allSatisfy { $1-$0 < 0.080 },
                "Normal pacing made a visible tracking gap")
        print("PASS: ±3ms arrival jitter retains ~24Hz")

        var stall = CaptureCadence()
        require(stall.admit(at: 1), "First frame rejected")
        require(stall.admit(at: 30), "Recovery frame rejected")
        require(!stall.admit(at: 30.001), "Caught up old inference debt after stall")
        require(stall.admit(at: 30.05), "Did not resume after stall")
        require(!stall.admit(at: 30.05), "Duplicated callback processed")
        require(!stall.admit(at: 29), "Clock regression processed")
        for bad in [Double.nan, .infinity, -.infinity, -1] {
            require(!stall.admit(at: bad), "Invalid timestamp processed")
        }
        require(stall.admit(at: 30.1), "Invalid timestamp poisoned pacing")
        stall.reset()
        require(stall.admit(at: 0), "Explicit camera reset retained old timing")
        print("PASS: stall recovery, duplicate/backward clocks, finite times, reset")

        // Combined scheduling sanity: tracking is smoother, but the sign model
        // still gets at most ~4 requests/s and <=19 observed samples per window.
        var gate = CaptureCadence()
        var policy = LiveWindowPolicy()
        var jobs = 0, frames = 0
        let hand = TrackedHand(handedness: "Right", handednessScore: 1,
                               joints: Array(repeating: Joint(x: 0.5, y: 0.5, z: 0), count: 21))
        for i in 0..<1800 {
            let now = 100+Double(i)/30
            guard gate.admit(at: now) else { continue }
            frames += 1
            let time = Int((now*1000).rounded())
            let frame = LandmarkFrame(timestampMS: time, hands: [hand],
                                      imageAspectRatio: 0.5625, mirrored: true)
            if let job = policy.ingest(frame, nowMS: time) {
                jobs += 1
                require(job.frames.count <= 19, "Camera cadence inflated model tensor")
                policy.complete(job, result: Classification(candidates: [], unknown: true), nowMS: time+5)
            }
        }
        require((210...240).contains(jobs), "Camera pacing starved or flooded sign inference")
        require(frames == 1440, "Combined pipeline lost capture rate")
        print("PASS: combined virtual 60s stream: \(frames) tracked frames, \(jobs) model jobs")
    }
}
