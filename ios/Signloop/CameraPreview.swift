import AVFoundation
import SwiftUI

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let mirrored: Bool

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.mirrored = mirrored
        view.setNeedsLayout()
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var mirrored = true

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let connection = previewLayer.connection else { return }
        if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
    }
}

struct JointOverlay: View {
    let hands: [TrackedHand]
    let sourceSize: CGSize
    let showNumbers: Bool

    private let chains = [[0, 1, 2, 3, 4], [0, 5, 6, 7, 8], [5, 9, 10, 11, 12],
                          [9, 13, 14, 15, 16], [13, 17, 18, 19, 20], [0, 17]]

    var body: some View {
        Canvas { context, size in
            for hand in hands {
                let color: Color = hand.handedness == "Left" ? .mint : .orange
                let points = hand.joints.map { joint -> CGPoint in
                    let point = overlayPoint(joint, sourceWidth: sourceSize.width,
                                             sourceHeight: sourceSize.height,
                                             viewWidth: size.width, viewHeight: size.height)
                    return CGPoint(x: point.0, y: point.1)
                }
                guard points.count == 21 else { continue }
                for chain in chains {
                    var path = Path()
                    path.move(to: points[chain[0]])
                    for index in chain.dropFirst() { path.addLine(to: points[index]) }
                    context.stroke(path, with: .color(.black.opacity(0.35)), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                    context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
                for (index, point) in points.enumerated() {
                    let tip = [4, 8, 12, 16, 20].contains(index)
                    let radius: CGFloat = tip ? 5 : 3.5
                    let circle = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                                       width: radius * 2, height: radius * 2))
                    context.fill(circle, with: .color(tip ? .white : color))
                    if showNumbers {
                        context.draw(Text("\(index)").font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.white), at: CGPoint(x: point.x + 11, y: point.y - 11))
                    }
                }
                context.draw(Text(hand.handedness.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundColor(color),
                    at: CGPoint(x: points[0].x, y: points[0].y + 22))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
