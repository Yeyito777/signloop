import SwiftUI
import MediaPipeTasksVision

struct SkeletonOverlay: View {
    let frame: SkeletonFrame?
    let mirrored: Bool
    let showHands: Bool
    let showPose: Bool
    let showFace: Bool
    let showNumbers: Bool
    let selected: SkeletonProbe
    var onProbe: (SkeletonProbe) -> Void
    private static let faceEdges = FaceLandmarker.contoursConnections().map { (Int($0.start), Int($0.end)) }

    private func screen(_ point: SkeletonPoint, _ frame: SkeletonFrame, _ size: CGSize) -> CGPoint {
        let xy = SkeletonGeometry.project(point, width: Double(frame.width), height: Double(frame.height),
            viewWidth: size.width, viewHeight: size.height, mirrored: mirrored)
        return CGPoint(x: xy.0, y: xy.1)
    }

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                guard let frame else { return }
                func draw(_ points: [SkeletonPoint], edges: [(Int, Int)], color: Color, face: Bool = false) {
                    let valid = Dictionary(uniqueKeysWithValues: points.filter(\.usable).map { ($0.id, $0) })
                    var path = Path()
                    for (a, b) in edges {
                        guard let p = valid[a], let q = valid[b] else { continue }
                        path.move(to: screen(p, frame, size))
                        path.addLine(to: screen(q, frame, size))
                    }
                    context.stroke(path, with: .color(.black.opacity(0.4)), lineWidth: face ? 3 : 6)
                    context.stroke(path, with: .color(color), lineWidth: face ? 1.2 : 3)
                    for p in points where p.usable {
                        let center = screen(p, frame, size)
                        let r = face ? 1.1 : 3.5
                        context.fill(Path(ellipseIn: CGRect(x: center.x-r, y: center.y-r, width: r*2, height: r*2)),
                                     with: .color(color))
                        // Face numbers only on useful anchors; all 478 remain tappable.
                        if showNumbers && (!face || [1, 4, 10, 13, 14, 33, 61, 152, 263, 291].contains(p.id)) {
                            context.draw(Text("\(p.id)").font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.white), at: CGPoint(x: center.x+9, y: center.y-9))
                        }
                    }
                }
                if showPose { draw(frame.pose, edges: SkeletonGeometry.poseEdges, color: .cyan) }
                if showFace { draw(frame.face, edges: Self.faceEdges, color: .yellow, face: true) }
                if showHands {
                    let edges = SkeletonGeometry.handChains.flatMap { Array(zip($0, $0.dropFirst())) }
                    for hand in frame.hands {
                        let color: Color = hand.poseSide == "Left" ? .mint : hand.poseSide == "Right" ? .orange : .white
                        draw(hand.points, edges: edges, color: color)
                        if showPose, let side = hand.poseSide,
                           let wrist = hand.points.first(where: { $0.id == 0 && $0.usable }),
                           let elbow = frame.pose.first(where: { $0.id == (side == "Left" ? 13 : 14) && $0.usable }) {
                            var bridge = Path()
                            bridge.move(to: screen(elbow, frame, size))
                            bridge.addLine(to: screen(wrist, frame, size))
                            context.stroke(bridge, with: .color(color), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                        }
                    }
                }
                if let p = frame.point(selected) {
                    let center = screen(p, frame, size)
                    context.stroke(Path(ellipseIn: CGRect(x: center.x-9, y: center.y-9, width: 18, height: 18)),
                                   with: .color(.white), lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard let frame else { return }
                var candidates: [(SkeletonProbe, SkeletonPoint)] = []
                if showPose { candidates += frame.pose.map { (SkeletonProbe(part: "pose", id: $0.id), $0) } }
                if showFace { candidates += frame.face.map { (SkeletonProbe(part: "face", id: $0.id), $0) } }
                if showHands {
                    for (i, hand) in frame.hands.enumerated() {
                        candidates += hand.points.map { (SkeletonProbe(part: hand.poseSide ?? "hand\(i)", id: $0.id), $0) }
                    }
                }
                let nearest = candidates.filter { $0.1.usable }.map { probe, point in
                    let p = screen(point, frame, geometry.size)
                    return (probe, hypot(p.x-location.x, p.y-location.y))
                }.min { $0.1 < $1.1 }
                if let nearest, nearest.1 < 24 { onProbe(nearest.0) }
            }
        }
        .accessibilityHidden(true) // Equivalent labeled picker in the inspector.
    }
}
