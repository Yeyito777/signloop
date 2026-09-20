import Foundation

enum ExpressionMeasurement: String {
    case upperLip = "face-geometry-mouth-v1"
    case noseScrunch = "face-geometry-nose-v2"
    case jawDrop = "face-geometry-jaw-nose-v3"
    static let current: Self = .jawDrop
    var usesNose: Bool { self != .upperLip }
    var usesJaw: Bool { self == .jawDrop }

    func bounds(for cue: ExpressionCue) -> ClosedRange<Double> {
        usesNose && cue == .disgust ? -2...0 : cue.rawBounds
    }
}

/// Dimensionless measurements from the SAME fresh frame. No identity matching.
struct ExpressionObservation {
    var values: [ExpressionCue: Double]
    var pose: ExpressionPose
    var camera: String
    var measurement: ExpressionMeasurement = .current
    var jawOpening: Double?

    var isValid: Bool {
        ["front", "back"].contains(camera) && pose.isValid &&
        (!measurement.usesJaw || jawOpening.map { $0.isFinite && (0...1).contains($0) } == true) &&
        values.count == ExpressionCue.allCases.count &&
        ExpressionCue.allCases.allSatisfy { cue in
            values[cue].map { $0.isFinite && measurement.bounds(for: cue).contains($0) } ?? false
        }
    }

    static func from(_ frame: SkeletonFrame, measurement: ExpressionMeasurement = .current) -> ExpressionObservation? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        // Convert to pixels BEFORE distances: portrait normalized x/y have
        // different scales. Explicit IDs survive filtered/missing landmarks.
        var points: [Int: SIMD2<Double>] = [:]
        for point in frame.face where point.usable {
            guard points[point.id] == nil else { return nil }
            points[point.id] = SIMD2(Double(point.x) * Double(frame.width),
                                    Double(point.y) * Double(frame.height))
        }
        func dot(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x*b.x + a.y*b.y }
        func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x*b.y - a.y*b.x }
        // MediaPipe FaceMesh eye/brow topology. Height above the eye-corner
        // line is roll invariant; eyelid opening cannot move this reference.
        func eye(_ cornerA: Int, _ cornerB: Int, _ lids: [(Int, Int)],
                 _ brow: [Int], _ inner: Int, _ outer: Int) -> (Double, Double, Double)? {
            guard let a = points[cornerA], let b = points[cornerB] else { return nil }
            let axis = b-a, widthSquared = dot(axis, axis)
            guard widthSquared >= 16 else { return nil }
            func height(_ id: Int) -> Double? {
                points[id].map { -cross(axis, $0-a) / widthSquared }
            }
            var gaps: [Double] = []
            for (upper, lower) in lids {
                guard let u = height(upper), let l = height(lower), u >= l else { return nil }
                gaps.append(u-l)
            }
            let heights = brow.compactMap(height)
            guard heights.count == brow.count, let i = height(inner), let o = height(outer) else { return nil }
            return (gaps.reduce(0,+) / Double(gaps.count),
                    heights.reduce(0,+) / Double(heights.count), i-o)
        }
        guard let right = eye(33,133, [(159,145), (158,153)], [105,107], 107,70),
              let left = eye(362,263, [(386,374), (385,380)], [334,336], 336,300),
              let a = points[33], let b = points[263], let nose = points[1] else { return nil }
        let axis = b-a, spanSquared = dot(axis, axis)
        guard spanSquared >= 64 else { return nil }
        func bilateral(_ name: String) -> Double? {
            guard let l = frame.expressions[name + "Left"], let r = frame.expressions[name + "Right"],
                  l.isFinite, r.isFinite, (0...1).contains(l), (0...1).contains(r) else { return nil }
            return (Double(l)+Double(r))/2
        }
        guard let smile = bilateral("mouthSmile") else { return nil }
        let fifth: Double
        switch measurement {
        case .upperLip:
            guard let lip = bilateral("mouthUpperUp") else { return nil }
            fifth = lip
        case .noseScrunch, .jawDrop:
            // FaceMesh 168 is the nose root; 98/327 are the paired nasal wings.
            // Scrunching raises the wings toward the root. Normalize their
            // projected separation by the eye-corner span, not nose width or
            // lip position. This is a geometric proxy, not wrinkle texture.
            guard let root = points[168], let rightWing = points[98], let leftWing = points[327] else { return nil }
            fifth = -cross(axis, (rightWing+leftWing)/2-root)/spanSquared
        }
        let opening: Double
        var jawOpening: Double?
        if measurement.usesJaw {
            guard let upperLip = points[13], let lowerLip = points[14],
                  let jaw = frame.expressions["jawOpen"], jaw.isFinite, (0...1).contains(jaw) else { return nil }
            // Require BOTH visible vertical mouth opening and jaw opening.
            // Lip parting with a closed jaw cannot substitute for a jaw drop.
            // Eye spacing normalizes scale without shrinking when a smile widens.
            let gap = max(0, cross(axis, lowerLip-upperLip)/spanSquared)
            opening = min(gap, Double(jaw))
            jawOpening = Double(jaw)
        } else {
            opening = (right.0 + left.0)/2
        }
        let observation = ExpressionObservation(values: [
            .joy: smile,
            .anger: -(right.1 + left.1)/2, // Lower than YOUR resting brows = positive change.
            .fear: opening,
            .sadness: (right.2 + left.2)/2, // Inner lift relative to outer brow, not whole-brow raise.
            .disgust: fifth,
        ], pose: ExpressionPose(horizontal: dot(axis, nose-(a+b)/2)/spanSquared,
                                vertical: cross(axis, nose-(a+b)/2)/spanSquared), camera: frame.camera,
           measurement: measurement, jawOpening: jawOpening)
        return observation.isValid ? observation : nil
    }
}

/// Coarse view-angle guard, not a calibrated 3D head pose estimate.
struct ExpressionPose: Codable, Equatable {
    var horizontal: Double
    var vertical: Double
    var isValid: Bool { horizontal.isFinite && vertical.isFinite && abs(horizontal) <= 1 && abs(vertical) <= 1 }
    func isNear(_ other: Self) -> Bool {
        abs(horizontal-other.horizontal) <= 0.10 && abs(vertical-other.vertical) <= 0.10
    }
}
