import AVFoundation
import Combine
import ExpoModulesCore
import UIKit
import QuartzCore

final class SignloopCameraView: ExpoView {
    let onStatus = EventDispatcher()
    let onSign = EventDispatcher()
    let tracker: CameraTracker
    var active = false
    var captureId = 0
    var showSkeleton = true
    private(set) var isCapturing = false

    private let preview = PreviewView()
    private let skeleton = CAShapeLayer()
    private var subscription: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    private var appliedCaptureId = -1
    private var lastStatus = ""
    private var lastSign = ""
    private var lastSignAt = 0.0
    private var renderScheduled = false
    private var expiryTimer: Timer?

    required init(appContext: AppContext? = nil) {
        let resourceURL = Bundle(for: SignloopCameraView.self).url(forResource: "SignloopCameraModels", withExtension: "bundle")
            ?? Bundle.main.url(forResource: "SignloopCameraModels", withExtension: "bundle")
        let model = resourceURL.flatMap(Bundle.init(url:))?.path(forResource: "gesture_recognizer", ofType: "task")
        tracker = CameraTracker(modelPath: model)
        super.init(appContext: appContext)
        clipsToBounds = true
        backgroundColor = .black
        preview.previewLayer.session = tracker.session
        preview.previewLayer.videoGravity = .resizeAspectFill
        addSubview(preview)
        skeleton.strokeColor = UIColor(red: 1, green: 0.95, blue: 0.73, alpha: 1).cgColor
        skeleton.fillColor = UIColor.clear.cgColor
        skeleton.lineWidth = 2.5
        skeleton.lineCap = .round
        skeleton.lineJoin = .round
        layer.addSublayer(skeleton)
        // Coalesce all @Published changes from a frame and read the settled snapshot.
        subscription = tracker.objectWillChange.sink { [weak self] _ in
            guard let self, !self.renderScheduled else { return }
            self.renderScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.renderScheduled = false
                self?.renderTracking()
            }
        }
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.stop()
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.synchronize()
        })
    }

    deinit {
        expiryTimer?.invalidate()
        subscription?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        tracker.pause()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        synchronize()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        preview.frame = bounds
        skeleton.frame = bounds
        renderTracking()
    }

    func synchronize() {
        guard active, window != nil, UIApplication.shared.applicationState == .active else {
            stop()
            return
        }
        #if targetEnvironment(simulator)
        emit("unavailable", message: "Camera preview needs a physical iPhone.")
        return
        #else
        guard !isCapturing || appliedCaptureId != captureId else {
            renderTracking()
            return
        }
        isCapturing = true
        appliedCaptureId = captureId
        lastStatus = ""
        lastSign = ""
        emit("starting")
        tracker.start()
        expiryTimer?.invalidate()
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tracker.expireLocalResult()
        }
        #endif
    }

    private func stop() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        guard isCapturing else { return }
        isCapturing = false
        skeleton.path = nil
        tracker.pause()
    }

    private func emit(_ status: String, handCount: Int = 0, message: String = "") {
        let key = "\(captureId):\(status):\(handCount):\(message)"
        guard key != lastStatus else { return }
        lastStatus = key
        onStatus(["captureId": captureId, "status": status, "handCount": handCount, "message": message])
        if status != "tracking" { emitSign(nil) }
    }

    private func emitSign(_ label: String?) {
        let key = "\(captureId):\(label ?? "unknown")"
        let now = Date().timeIntervalSince1970 * 1000
        // Refresh candidate expiry while held, without flooding the JS bridge.
        guard key != lastSign || (label != nil && now - lastSignAt >= 250) else { return }
        lastSign = key
        lastSignAt = now
        let observed = now - Double(tracker.frameAgeMS ?? 0)
        onSign(["captureId": captureId, "label": label as Any? ?? NSNull(), "observedAtMS": observed])
    }

    private func renderTracking() {
        guard isCapturing else { return }
        if tracker.permissionDenied {
            skeleton.path = nil
            emit("denied")
            return
        }
        if let error = tracker.errorMessage {
            skeleton.path = nil
            emit("error", message: error)
            return
        }
        guard tracker.isRunning else {
            skeleton.path = nil
            emit("starting")
            return
        }

        let path = UIBezierPath()
        var visibleHands = 0
        let chains = [[0, 1, 2, 3, 4], [0, 5, 6, 7, 8], [5, 9, 10, 11, 12],
                      [9, 13, 14, 15, 16], [13, 17, 18, 19, 20], [0, 17]]
        for hand in tracker.hands where hand.joints.count == 21 {
            let points = hand.joints.map { joint -> CGPoint in
                let point = overlayPoint(joint, sourceWidth: tracker.frameSize.width,
                    sourceHeight: tracker.frameSize.height, viewWidth: bounds.width, viewHeight: bounds.height)
                return CGPoint(x: point.0, y: point.1)
            }
            // The split-screen crop can hide landmarks even when the full sensor sees them.
            if points.allSatisfy({ bounds.contains($0) }) { visibleHands += 1 }
            for chain in chains {
                path.move(to: points[chain[0]])
                for index in chain.dropFirst() { path.addLine(to: points[index]) }
            }
            for point in points { path.append(UIBezierPath(ovalIn: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4))) }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        skeleton.path = showSkeleton ? path.cgPath : nil
        emitSign(visibleHands > 0 ? tracker.localSign : nil)
        CATransaction.commit()
        // No face, distance, lighting, emotion, or sign-confidence inference here.
        emit(visibleHands > 0 ? "tracking" : "searching", handCount: visibleHands)
    }
}
