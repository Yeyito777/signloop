import Foundation

/// Swift port of recognition/segmenter.py:
/// IDLE -> POSSIBLE_SIGN -> SIGN_IN_PROGRESS -> SIGN_COMPLETE -> PREDICTION.
/// Deterministic, integer milliseconds. Parity with Python is checked against golden traces.
struct SignSegmenter {
    enum State: String { case idle, possibleSign = "possible_sign", inProgress = "sign_in_progress",
                         complete = "sign_complete", prediction }

    struct Config: Codable, Equatable {
        var settleMS = 200
        var lagFrames = 5
        var shapeWeight = 1.0
        var eOn = 1.2
        var eOff = 0.4
        var onsetMS = 100
        var holdMS = 250
        var lostMS = 200
        var minMS = 400
        var maxMS = 3000
        var prerollMS = 200
        var tailMS = 100
        var dwellMS = 600
        var rearmAbsentMS = 300
        var minGapMS = 500
        var maxFrameGapMS = 150
        enum CodingKeys: String, CodingKey {
            case settleMS = "settle_ms", lagFrames = "lag_frames", shapeWeight = "shape_weight", eOn = "e_on"
            case eOff = "e_off", onsetMS = "onset_ms", holdMS = "hold_ms", lostMS = "lost_ms", minMS = "min_ms"
            case maxMS = "max_ms", prerollMS = "preroll_ms", tailMS = "tail_ms", dwellMS = "dwell_ms"
            case rearmAbsentMS = "rearm_absent_ms", minGapMS = "min_gap_ms", maxFrameGapMS = "max_frame_gap_ms"
        }
    }

    struct Segment {
        var frames: [LandmarkFrame]
        var startMS: Int
        var endMS: Int
        var reason: String
    }

    private static let border = 0.02
    private static let palmCore = [0, 5, 9, 13, 17]

    private struct Obs {
        var t: Int
        var frame: LandmarkFrame
        var present: Bool
        var inside: Bool
        var slots: [Int: (xy: [Double], scale: Double)]   // xy: 21*2, aspect-corrected
    }

    let cfg: Config
    private(set) var state = State.idle
    private var obs: [Obs] = []
    private(set) var armed = true
    private var settleStart: Int?
    private var possibleStart: Int?
    private var onset: Int?
    private var segStart: Int?
    private var lastActive: Int?
    private var restSince: Int?
    private var absentSince: Int?
    private var goneSince: Int?
    private var lastFinish: Int?
    private var lastT: Int?

    init(_ cfg: Config = Config()) { self.cfg = cfg }

    mutating func reset() {
        state = .idle; obs = []; armed = true
        settleStart = nil; possibleStart = nil; onset = nil; segStart = nil; lastActive = nil
        restSince = nil; absentSince = nil; goneSince = nil; lastFinish = nil; lastT = nil
    }

    mutating func finish(_ t: Int) {
        state = .idle; armed = false; lastFinish = t
        settleStart = nil; possibleStart = nil; onset = nil; segStart = nil
        restSince = nil; absentSince = nil; goneSince = nil
    }

    private static func summarize(_ frame: LandmarkFrame) -> Obs {
        var slots: [Int: (xy: [Double], scale: Double)] = [:]
        var inside = true
        let aspectValue = Double(frame.imageAspectRatio ?? 0)
        let aspect = aspectValue == 0 ? 1.0 : aspectValue
        let mirrored = frame.mirrored ?? true
        for hand in frame.hands {
            guard hand.joints.count == 21 else { continue }
            var xy = [Double](repeating: 0, count: 42)
            var finite = true
            for (j, p) in hand.joints.enumerated() {
                xy[j * 2] = Double(p.x); xy[j * 2 + 1] = Double(p.y)
                if !(xy[j * 2].isFinite && xy[j * 2 + 1].isFinite) { finite = false }
            }
            guard finite else { continue }
            for j in palmCore {
                if min(xy[j * 2], xy[j * 2 + 1]) < border || max(xy[j * 2], xy[j * 2 + 1]) > 1 - border { inside = false }
            }
            var side = hand.handedness
            if !mirrored {
                side = side == "Left" ? "Right" : (side == "Right" ? "Left" : side)
                for j in 0..<21 { xy[j * 2] = 1 - xy[j * 2] }
            }
            guard side == "Left" || side == "Right" else { continue }
            for j in 0..<21 { xy[j * 2] *= aspect }
            var spokeSum = 0.0
            for j in [5, 9, 13, 17] {
                let dx: Double = xy[j * 2] - xy[0]
                let dy: Double = xy[j * 2 + 1] - xy[1]
                spokeSum += hypot(dx, dy)
            }
            let scale = spokeSum / 4
            if scale < 0.015 { continue }
            slots[side == "Left" ? 0 : 1] = (xy, scale)
        }
        let present = !slots.isEmpty
        return Obs(t: frame.timestampMS, frame: frame, present: present, inside: present && inside, slots: slots)
    }

    private static func energy(_ cur: Obs, _ ref: Obs?, maxGap: Int, shapeWeight: Double) -> Double? {
        guard let ref, cur.t > ref.t, cur.t - ref.t <= maxGap * 4 else { return nil }
        let dt = Double(cur.t - ref.t) / 1000
        var best: Double?
        for (slot, now) in cur.slots {
            guard let before = ref.slots[slot] else { continue }
            let s = (now.scale + before.scale) / 2
            func centroid(_ xy: [Double]) -> (Double, Double) {
                var x = 0.0, y = 0.0
                for j in 0..<21 { x += xy[j * 2]; y += xy[j * 2 + 1] }
                return (x / 21, y / 21)
            }
            let c0 = centroid(before.xy), c1 = centroid(now.xy)
            let trans = hypot(c1.0 - c0.0, c1.1 - c0.1) / s / dt
            var shape = 0.0
            for j in 0..<21 {
                shape += hypot((now.xy[j * 2] - c1.0) - (before.xy[j * 2] - c0.0),
                               (now.xy[j * 2 + 1] - c1.1) - (before.xy[j * 2 + 1] - c0.1))
            }
            shape = shape / 21 / s / dt
            let e = max(trans, shapeWeight * shape)
            best = best.map { max($0, e) } ?? e
        }
        return best
    }

    /// Feed one frame. Returns a Segment exactly once per completed attempt.
    mutating func update(_ frame: LandmarkFrame) -> Segment? {
        let t = frame.timestampMS
        if let last = lastT, t <= last || t - last > cfg.maxFrameGapMS * 4 {
            let keep = state == .prediction
            let lf = lastFinish
            reset()
            if keep { state = .prediction }
            lastFinish = lf
        }
        lastT = t
        let o = Self.summarize(frame)
        var ref: Obs?
        for back in cfg.lagFrames..<(cfg.lagFrames + 4) where obs.count >= back && obs[obs.count - back].present {
            ref = obs[obs.count - back]
            break
        }
        let e = o.present ? Self.energy(o, ref, maxGap: cfg.maxFrameGapMS, shapeWeight: cfg.shapeWeight) : nil
        obs.append(o)
        obs.removeAll { $0.t < t - (cfg.maxMS + 2000) }
        if state == .prediction { return nil }

        let moving = e.map { $0 >= cfg.eOn } ?? false
        let resting = o.present && (e == nil || e! < cfg.eOff)
        if o.present { goneSince = nil } else if goneSince == nil { goneSince = t }
        if !armed, let g = goneSince, t - g >= cfg.rearmAbsentMS { armed = true }
        let gapOK = lastFinish == nil || t - lastFinish! >= cfg.minGapMS
        let briefDropout = !o.present && goneSince != nil && t - goneSince! < cfg.lostMS
        if (state == .idle || state == .possibleSign) && briefDropout { return nil }

        switch state {
        case .idle:
            guard o.inside else { settleStart = nil; onset = nil; return nil }
            if settleStart == nil { settleStart = t }
            let settled = t - settleStart! >= cfg.settleMS
            if moving && gapOK {
                if onset == nil { onset = t }
                if settled { armed = true }
            } else { onset = nil }
            if armed && gapOK && settled {
                state = .possibleSign
                possibleStart = settleStart
                restSince = resting ? t : nil
            }
            return nil
        case .possibleSign:
            guard o.inside else { state = .idle; settleStart = nil; onset = nil; restSince = nil; return nil }
            if moving {
                if onset == nil { onset = t }
                restSince = nil
                if t - onset! >= cfg.onsetMS { begin(start: max(possibleStart!, onset! - cfg.prerollMS), t) }
                return nil
            }
            onset = nil
            if resting {
                if restSince == nil { restSince = t }
                if t - restSince! >= cfg.dwellMS { return complete(restSince!, t, "static_hold") }
            } else { restSince = nil }
            return nil
        case .inProgress:
            if o.present { absentSince = nil } else if absentSince == nil { absentSince = t }
            if let e, e >= cfg.eOff { lastActive = t; restSince = nil }
            else if o.present && restSince == nil { restSince = t }
            if let a = absentSince, t - a >= cfg.lostMS { return complete(segStart!, a, "hand_left") }
            if let r = restSince, t - r >= cfg.holdMS {
                return complete(segStart!, (lastActive ?? t) + cfg.tailMS, "movement_rest")
            }
            if t - segStart! >= cfg.maxMS { return complete(segStart!, t, "max_duration") }
            return nil
        case .complete, .prediction:
            return nil
        }
    }

    private mutating func begin(start: Int, _ t: Int) {
        state = .inProgress; armed = true; segStart = start; lastActive = t
        restSince = nil; absentSince = nil; onset = nil
    }

    private mutating func complete(_ start: Int, _ end: Int, _ reason: String) -> Segment? {
        let frames = obs.filter { $0.t >= start && $0.t <= end }.map(\.frame)
        state = .prediction
        if end - start < cfg.minMS || frames.count < 6 || !frames.contains(where: { !$0.hands.isEmpty }) {
            finish(end)
            armed = true          // a discarded blip must not lock the recognizer out
            lastFinish = nil
            return nil
        }
        return Segment(frames: frames, startMS: start, endMS: end, reason: reason)
    }
}
