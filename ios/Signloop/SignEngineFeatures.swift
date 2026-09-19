import Foundation

/// Swift port of recognition/features.py. Same math, same constants, so the Core ML model
/// sees the tensors it was trained on. Parity is enforced by golden vectors
/// (ios/Tests/SignEngineParity.swift). Only anchorless input is supported here: LandmarkFrame
/// carries no face/torso landmarks, so the anchor channels and their mask stay zero, exactly as
/// the Python code produces when no anchor is present.
enum SignFeatures {
    static let joints = 21
    static let nodeChannels = 6
    static let globalCount = 39
    static let globalWidth = 78
    static let motionCount = 21
    static let metaCount = 6
    static let minPalm = 0.015
    static let velScale = 5.0
    static let accScale = 50.0
    static let parent = [-1, 0, 1, 2, 3, 0, 5, 6, 7, 0, 9, 10, 11, 0, 13, 14, 15, 0, 17, 18, 19]
    static let tips = [4, 8, 12, 16, 20]
    static let angleTriples = [(0, 1, 2), (1, 2, 3), (2, 3, 4), (0, 5, 6), (5, 6, 7), (6, 7, 8),
                               (0, 9, 10), (9, 10, 11), (10, 11, 12), (0, 13, 14), (13, 14, 15), (14, 15, 16),
                               (0, 17, 18), (17, 18, 19), (18, 19, 20)]
    static let abduction = [(5, 9), (9, 13), (13, 17), (1, 5)]

    struct Config: Codable, Equatable {
        var steps = 32
        var maxGapMS = 150.0
        var derivatives = true
        var motion = true
        var anchors = true
        var rotate = false
        var angles = true
        var canonicalDominant = false
        enum CodingKeys: String, CodingKey {
            case steps, derivatives, motion, anchors, rotate, angles
            case maxGapMS = "max_gap_ms", canonicalDominant = "canonical_dominant"
        }
        /// Options the Swift port does not implement. The engine refuses such models.
        var unsupported: [String] {
            var out: [String] = []
            if rotate { out.append("rotate") }
            if canonicalDominant { out.append("canonical_dominant") }
            return out
        }
    }

    struct Output {
        var nodes: [Float]     // T x 2 x 21 x 6
        var glob: [Float]      // T x 2 x 78
        var motion: [Float]    // T x 21
        var mask: [Float]      // T x 3
        var meta: [Float]      // 6
        var quality: Double
        var steps: Int
    }

    enum Failure: Error { case noFrames, badTimestamps, badAspect, tooShort }

    /// Aspect-corrected, mirror-canonical observations. slot 0 = Left, 1 = Right.
    struct Raw {
        var t: [Double] = []
        var xyz: [Double] = []      // n*2*21*3
        var present: [Bool] = []    // n*2
        var score: [Double] = []    // n*2
        var n: Int { t.count }
    }

    static func raw(from frames: [LandmarkFrame]) throws -> Raw {
        guard !frames.isEmpty else { throw Failure.noFrames }
        var r = Raw()
        let n = frames.count
        r.t = frames.map { Double($0.timestampMS) }
        for i in 1..<max(n, 1) where r.t[i] <= r.t[i - 1] { throw Failure.badTimestamps }
        r.xyz = Array(repeating: 0, count: n * 2 * joints * 3)
        r.present = Array(repeating: false, count: n * 2)
        r.score = Array(repeating: 0, count: n * 2)
        for (i, frame) in frames.enumerated() {
            let aspectValue = Double(frame.imageAspectRatio ?? 0)
            let aspect = aspectValue == 0 ? 1.0 : aspectValue
            let mirrored = frame.mirrored ?? true
            guard aspect.isFinite, aspect >= 0.1, aspect <= 10 else { throw Failure.badAspect }
            for hand in frame.hands {
                var side = hand.handedness
                if !mirrored { side = side == "Left" ? "Right" : (side == "Right" ? "Left" : side) }
                guard side == "Left" || side == "Right", hand.joints.count == joints else { continue }
                let slot = side == "Left" ? 0 : 1
                var s = Double(hand.handednessScore)
                s = s.isFinite ? min(1, max(0, s)) : 0.5
                var pts = [Double](repeating: 0, count: joints * 3)
                var ok = true
                for (j, p) in hand.joints.enumerated() {
                    let x = (mirrored ? Double(p.x) : 1 - Double(p.x)) * aspect
                    let y = Double(p.y), z = Double(p.z) * aspect
                    if !(x.isFinite && y.isFinite && z.isFinite) || max(abs(x), abs(y), abs(z)) > 10 { ok = false; break }
                    pts[j * 3] = x; pts[j * 3 + 1] = y; pts[j * 3 + 2] = z
                }
                guard ok else { continue }
                let palm = hypot(pts[9 * 3] - pts[0], pts[9 * 3 + 1] - pts[1])
                if palm < minPalm { continue }
                if r.present[i * 2 + slot] && s <= r.score[i * 2 + slot] { continue }
                let base = (i * 2 + slot) * joints * 3
                for k in 0..<(joints * 3) { r.xyz[base + k] = pts[k] }
                r.present[i * 2 + slot] = true
                r.score[i * 2 + slot] = s
            }
        }
        return r
    }

    // MARK: resample

    private struct Resampled {
        var xyz: [Double]     // T*2*21*3
        var mask: [Double]    // T*2
        var score: [Double]   // T*2
        var duration: Double
    }

    private static func resample(_ raw: Raw, _ cfg: Config) throws -> Resampled {
        guard raw.n >= 2 else { throw Failure.tooShort }
        let T = cfg.steps
        let t0 = raw.t[0], t1 = raw.t[raw.n - 1]
        var grid = [Double](repeating: t1, count: T)
        for k in 0..<(T - 1) {
            let fraction: Double = Double(k) / Double(T - 1)
            grid[k] = t0 + (t1 - t0) * fraction
        }
        var out = Resampled(xyz: Array(repeating: 0, count: T * 2 * joints * 3),
                            mask: Array(repeating: 0, count: T * 2), score: Array(repeating: 0, count: T * 2),
                            duration: t1 - t0)
        for s in 0..<2 {
            let idx = (0..<raw.n).filter { raw.present[$0 * 2 + s] }
            guard !idx.isEmpty else { continue }
            let ts = idx.map { raw.t[$0] }
            for (k, tau) in grid.enumerated() {
                // numpy.searchsorted(side="left")
                var lo = 0, hi = ts.count
                while lo < hi { let mid = (lo + hi) / 2; if ts[mid] < tau { lo = mid + 1 } else { hi = mid } }
                let j = lo
                let dst = (k * 2 + s) * joints * 3
                if j < ts.count && abs(ts[j] - tau) < 1e-6 {
                    let src = (idx[j] * 2 + s) * joints * 3
                    for q in 0..<(joints * 3) { out.xyz[dst + q] = raw.xyz[src + q] }
                    out.mask[k * 2 + s] = 1
                    out.score[k * 2 + s] = raw.score[idx[j] * 2 + s]
                    continue
                }
                if j == 0 || j == ts.count { continue }
                let a = idx[j - 1], b = idx[j]
                let span = raw.t[b] - raw.t[a]
                if span > cfg.maxGapMS { continue }
                let w = (tau - raw.t[a]) / span
                let sa = (a * 2 + s) * joints * 3, sb = (b * 2 + s) * joints * 3
                for q in 0..<(joints * 3) { out.xyz[dst + q] = (1 - w) * raw.xyz[sa + q] + w * raw.xyz[sb + q] }
                out.mask[k * 2 + s] = b == a + 1 ? 1 : 0.5
                out.score[k * 2 + s] = (1 - w) * raw.score[a * 2 + s] + w * raw.score[b * 2 + s]
            }
        }
        return out
    }

    // MARK: geometry

    private static func sub(_ a: ArraySlice<Double>, _ b: ArraySlice<Double>) -> [Double] {
        zip(a, b).map { $0 - $1 }
    }
    private static func unit(_ v: [Double]) -> [Double] {
        let n = max(sqrt(v.reduce(0) { $0 + $1 * $1 }), 1e-9)
        return v.map { $0 / n }
    }
    private static func dot(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
    private static func norm(_ a: [Double]) -> Double { sqrt(a.reduce(0) { $0 + $1 * $1 }) }

    /// rel: 21*3 wrist-centred, palm-scaled -> 39 values (same order as hand_geometry in Python).
    private static func geometry(_ rel: [Double]) -> [Double] {
        func p(_ j: Int) -> [Double] { [rel[j * 3], rel[j * 3 + 1], rel[j * 3 + 2]] }
        func vsub(_ a: [Double], _ b: [Double]) -> [Double] { [a[0] - b[0], a[1] - b[1], a[2] - b[2]] }
        var g: [Double] = []
        for (a, b, c) in angleTriples { g.append(dot(unit(vsub(p(a), p(b))), unit(vsub(p(c), p(b))))) }
        for (a, b) in abduction { g.append(dot(unit(p(a)), unit(p(b)))) }
        for i in 0..<5 { for j in (i + 1)..<5 where j < 5 { g.append(norm(vsub(p(tips[i]), p(tips[j])))) } }
        for t in tips { g.append(norm(p(t))) }
        let a = p(5), b = p(17)
        let cross = [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
        g.append(contentsOf: unit(cross))
        let ang = atan2(rel[9 * 3], -rel[9 * 3 + 1])
        g.append(sin(ang)); g.append(cos(ang))
        return g
    }

    private static func median(_ v: [Double]) -> Double {
        let s = v.sorted(), m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    // MARK: featurize

    static func featurize(_ raw: Raw, _ cfg: Config = Config()) throws -> Output {
        let bad = cfg.unsupported
        precondition(bad.isEmpty, "Unsupported feature options: \(bad)")
        let rs = try resample(raw, cfg)
        let T = cfg.steps
        func obs(_ k: Int, _ s: Int) -> Bool { rs.mask[k * 2 + s] > 0 }
        func at(_ k: Int, _ s: Int, _ j: Int, _ c: Int) -> Double { rs.xyz[((k * 2 + s) * joints + j) * 3 + c] }

        var scale = [Double](repeating: 0, count: T * 2)
        for k in 0..<T { for s in 0..<2 where obs(k, s) {
            var acc = 0.0
            for j in [5, 9, 13, 17] {
                acc += sqrt((0..<3).reduce(0.0) { $0 + pow(at(k, s, j, $1) - at(k, s, 0, $1), 2) })
            }
            scale[k * 2 + s] = acc / 4
        } }

        var nodes = [Float](repeating: 0, count: T * 2 * joints * nodeChannels)
        var glob = [Float](repeating: 0, count: T * 2 * globalWidth)
        var rawGlob = [Double](repeating: 0, count: T * 2 * globalCount)
        for k in 0..<T { for s in 0..<2 where obs(k, s) {
            let safe = max(scale[k * 2 + s], minPalm)
            var rel = [Double](repeating: 0, count: joints * 3)
            for j in 0..<joints { for c in 0..<3 { rel[j * 3 + c] = (at(k, s, j, c) - at(k, s, 0, c)) / safe } }
            for j in 0..<joints {
                let par = max(parent[j], 0)
                let base = ((k * 2 + s) * joints + j) * nodeChannels
                for c in 0..<3 {
                    nodes[base + c] = Float(rel[j * 3 + c])
                    nodes[base + 3 + c] = j == 0 ? 0 : Float(rel[j * 3 + c] - rel[par * 3 + c])
                }
            }
            var g = geometry(rel)
            if !cfg.angles { for q in 0..<(globalCount - 5) { g[q] = 0 } }
            for q in 0..<globalCount { rawGlob[(k * 2 + s) * globalCount + q] = g[q] }
        } }
        for k in 0..<T { for s in 0..<2 {
            let base = (k * 2 + s) * globalWidth
            for q in 0..<globalCount { glob[base + q] = Float(rawGlob[(k * 2 + s) * globalCount + q]) }
            if cfg.derivatives, k > 0, obs(k, s), obs(k - 1, s) {
                for q in 0..<globalCount {
                    glob[base + globalCount + q] = Float(rawGlob[(k * 2 + s) * globalCount + q]
                                                         - rawGlob[((k - 1) * 2 + s) * globalCount + q])
                }
            }
        } }

        // motion stream
        let dt = max(rs.duration / 1000 / Double(T - 1), 1e-3)
        var seen: [Double] = []
        for k in 0..<T { for s in 0..<2 where obs(k, s) { seen.append(scale[k * 2 + s]) } }
        let seqScale = max(seen.isEmpty ? 1.0 : median(seen), minPalm)
        var origin = [0.0, 0.0]
        let firstFrames = (0..<T).filter { obs($0, 0) || obs($0, 1) }.prefix(3)
        var pts: [[Double]] = []
        for k in firstFrames { for s in 0..<2 where obs(k, s) { pts.append([at(k, s, 0, 0), at(k, s, 0, 1)]) } }
        if !pts.isEmpty { origin = [pts.map { $0[0] }.reduce(0, +) / Double(pts.count), pts.map { $0[1] }.reduce(0, +) / Double(pts.count)] }
        var motion = [Double](repeating: 0, count: T * motionCount)
        var wrist = [[Double]](repeating: [0, 0], count: T * 2)
        for k in 0..<T { for s in 0..<2 { wrist[k * 2 + s] = [at(k, s, 0, 0), at(k, s, 0, 1)] } }
        for s in 0..<2 {
            let base = s * 9
            var pos = [[Double]](repeating: [0, 0], count: T)
            for k in 0..<T where obs(k, s) {
                pos[k] = [(wrist[k * 2 + s][0] - origin[0]) / seqScale, (wrist[k * 2 + s][1] - origin[1]) / seqScale]
                motion[k * motionCount + base] = pos[k][0]
                motion[k * motionCount + base + 1] = pos[k][1]
            }
            if cfg.derivatives && T >= 3 {
                for k in 1..<(T - 1) where obs(k - 1, s) && obs(k + 1, s) {
                    var vel = [(pos[k + 1][0] - pos[k - 1][0]) / (2 * dt), (pos[k + 1][1] - pos[k - 1][1]) / (2 * dt)]
                    vel = vel.map { min(50, max(-50, $0)) / velScale }
                    motion[k * motionCount + base + 4] = vel[0]
                    motion[k * motionCount + base + 5] = vel[1]
                    motion[k * motionCount + base + 8] = norm(vel)
                    if obs(k, s) {
                        for c in 0..<2 {
                            let a = (pos[k + 1][c] - 2 * pos[k][c] + pos[k - 1][c]) / (dt * dt)
                            motion[k * motionCount + base + 6 + c] = min(500, max(-500, a)) / accScale
                        }
                    }
                }
            }
        }
        for k in 0..<T where obs(k, 0) && obs(k, 1) {
            let d = [(wrist[k * 2 + 1][0] - wrist[k * 2][0]) / seqScale, (wrist[k * 2 + 1][1] - wrist[k * 2][1]) / seqScale]
            motion[k * motionCount + 18] = d[0]
            motion[k * motionCount + 19] = d[1]
            motion[k * motionCount + 20] = norm(d)
        }
        if !cfg.motion { motion = [Double](repeating: 0, count: motion.count) }

        // quality + meta
        var expected: [Int] = []
        for s in 0..<2 {
            let count = (0..<raw.n).filter { raw.present[$0 * 2 + s] }.count
            if Double(count) / Double(raw.n) >= 0.3 { expected.append(s) }
        }
        var quality = 0.0
        if !expected.isEmpty {
            var cover = 0.0, conf = 0.0
            for s in expected {
                let full = (0..<T).filter { rs.mask[$0 * 2 + s] == 1 }.count
                let half = (0..<T).filter { rs.mask[$0 * 2 + s] == 0.5 }.count
                cover += (Double(full) + 0.5 * Double(half)) / Double(T)
                let sc = (0..<T).filter { obs($0, s) }.map { rs.score[$0 * 2 + s] }
                conf += sc.isEmpty ? 0 : sc.reduce(0, +) / Double(sc.count)
            }
            quality = cover / Double(expected.count) * (conf / Double(expected.count))
        }
        let frac = { (s: Int) in Double((0..<T).filter { obs($0, s) }.count) / Double(T) }
        let bridged = Double(rs.mask.filter { $0 == 0.5 }.count) / Double(rs.mask.count)
        let meta: [Float] = [Float(log(max(rs.duration, 1) / 1000) + 0.5), Float(quality), Float(frac(0)), Float(frac(1)), Float(bridged), 0]
        var mask = [Float](repeating: 0, count: T * 3)
        for k in 0..<T { mask[k * 3] = Float(rs.mask[k * 2]); mask[k * 3 + 1] = Float(rs.mask[k * 2 + 1]) }
        return Output(nodes: nodes, glob: glob, motion: motion.map(Float.init), mask: mask, meta: meta,
                      quality: quality, steps: T)
    }

    static func featurize(frames: [LandmarkFrame], _ cfg: Config = Config()) throws -> Output {
        try featurize(try raw(from: frames), cfg)
    }
}
