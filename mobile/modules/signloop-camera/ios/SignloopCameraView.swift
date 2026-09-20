import AVFoundation
import Combine
import ExpoModulesCore
import UIKit
import QuartzCore

final class SignloopCameraView: ExpoView {
    let onStatus = EventDispatcher()
    let onPrediction = EventDispatcher()
    let onExpression = EventDispatcher()
    let tracker: SkeletonCameraTracker
    private let recognition = BasicLiveRecognition(activeLabels: BasicSignScore.presentationVocabulary,
        weMotionScale: BasicSignMatcher.compactWEMotionScale)
    var active = false
    var captureId = 0
    var showSkeleton = true
    private(set) var isCapturing = false

    private let preview = PreviewView()
    private let skeleton = CAShapeLayer()
    private var subscriptions: [AnyCancellable] = []
    private var observers: [NSObjectProtocol] = []
    private var appliedCaptureId = -1
    private var captureStartedMS = 0
    private var lastStatus = ""
    private var renderScheduled = false
    private var expiryTimer: Timer?
    private let missingModels: [String]
    private let modelBundle: Bundle
    private let faceModelAvailable: Bool
    private var expressions: GooseExpressionTracker
    private var lastExpression: GooseExpressionSnapshot?
    private var lastExpressionMS = -1000

    required init(appContext: AppContext? = nil) {
        let url = Bundle(for: SignloopCameraView.self).url(forResource: "SignloopCameraModels", withExtension: "bundle")
            ?? Bundle.main.url(forResource: "SignloopCameraModels", withExtension: "bundle")
        let modelBundle = url.flatMap(Bundle.init(url:)) ?? .main
        self.modelBundle = modelBundle
        faceModelAvailable = modelBundle.path(forResource: "face_landmarker", ofType: "task") != nil
        expressions = GooseExpressionTracker(source: Self.expressionProfile(in: modelBundle), modelAvailable: faceModelAvailable)
        missingModels = ["hand_landmarker", "pose_landmarker_lite"].filter {
            modelBundle.path(forResource: $0, ofType: "task") == nil
        }
        tracker = SkeletonCameraTracker(modelBundle: modelBundle, faceTrackingEnabled: faceModelAvailable)
        super.init(appContext: appContext)
        tracker.onSkeletonFrame = { [weak self] frame in
            guard let self, self.acceptsEvents, frame.timestampMS >= self.captureStartedMS else { return }
            self.expressions.observe(frame)
            self.emitExpression(at: frame.timestampMS)
            self.recognition.receive(frame)
        }
        tracker.onSkeletonReset = { [weak self] in
            self?.resetExpressions()
            self?.recognition.reset()
        }
        recognition.onPrediction = { [weak self] in self?.emitPrediction($0) }
        clipsToBounds = true
        backgroundColor = .black
        preview.mirrored = tracker.isFront
        preview.attach(session: tracker.session)
        // A short conversation tile must still show the whole signing area.
        preview.previewLayer.videoGravity = .resizeAspect
        addSubview(preview)
        skeleton.strokeColor = UIColor(red: 1, green: 0.95, blue: 0.73, alpha: 1).cgColor
        skeleton.fillColor = UIColor.clear.cgColor
        skeleton.lineWidth = 2.5
        skeleton.lineCap = .round
        skeleton.lineJoin = .round
        layer.addSublayer(skeleton)
        subscriptions = [tracker.objectWillChange.sink { [weak self] _ in self?.scheduleRender() },
                         recognition.objectWillChange.sink { [weak self] _ in self?.scheduleRender() }]
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.stop()
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in self?.synchronize() })
    }

    deinit {
        expiryTimer?.invalidate()
        subscriptions.forEach { $0.cancel() }
        observers.forEach(NotificationCenter.default.removeObserver)
        tracker.pause()
        recognition.reset()
    }

    private var acceptsEvents: Bool { active && isCapturing && appliedCaptureId == captureId }

    private static func expressionProfile(in bundle: Bundle) -> GooseExpressionProfile {
        let local = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DemoExpressionProfile.json")
        return GooseExpressionProfile.load(localURL: local,
            bundledURL: bundle.url(forResource: "DemoExpressionProfile", withExtension: "json"))
    }

    private func resetExpressions() {
        expressions.reset()
        lastExpression = nil
        lastExpressionMS = -1000
        emitExpression(at: Int(CaptureClock.now * 1000))
    }

    private func emitExpression(at timestamp: Int) {
        guard acceptsEvents, timestamp >= captureStartedMS else { return }
        let snapshot = expressions.snapshot
        // Transitions clear immediately; unchanged states heartbeat at 5 Hz so
        // JS can expire a stalled or interrupted camera without guessing.
        guard snapshot != lastExpression || timestamp - lastExpressionMS >= 200 else { return }
        lastExpression = snapshot
        lastExpressionMS = timestamp
        let ageMS = max(0, CaptureClock.now * 1000 - Double(timestamp))
        onExpression(["captureId": captureId, "observedAtMS": Date().timeIntervalSince1970 * 1000 - ageMS,
                      "status": snapshot.status.rawValue, "emotion": snapshot.emotion.rawValue])
    }

    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.renderScheduled = false
            self?.renderTracking()
        }
    }

    override func didMoveToWindow() { super.didMoveToWindow(); synchronize() }

    override func layoutSubviews() {
        super.layoutSubviews()
        preview.frame = bounds
        skeleton.frame = bounds
        renderTracking()
    }

    func synchronize() {
        guard active, window != nil, UIApplication.shared.applicationState == .active else { stop(); return }
        #if targetEnvironment(simulator)
        emit("unavailable", message: "Camera recognition needs a physical iPhone.")
        return
        #else
        guard missingModels.isEmpty else {
            emit("model-missing", message: "Missing tracking models: \(missingModels.joined(separator: ", ")). Rebuild the app.")
            return
        }
        guard !isCapturing || appliedCaptureId != captureId else { renderTracking(); return }
        let startCamera = !isCapturing
        isCapturing = true
        appliedCaptureId = captureId
        captureStartedMS = Int(CaptureClock.now * 1000)
        lastStatus = ""
        if startCamera {
            expressions = GooseExpressionTracker(source: Self.expressionProfile(in: modelBundle), modelAvailable: faceModelAvailable)
        }
        resetExpressions()
        recognition.reset()
        recognition.load() // Retries a failed load after the user chooses Retry.
        // Hand loss changes the JS generation. Keep expensive trackers alive;
        // discard pre-generation frames and matching jobs instead.
        if startCamera { tracker.start() }
        preview.mirrored = tracker.isFront
        preview.attach(session: tracker.session)
        preview.previewLayer.videoGravity = .resizeAspect
        expiryTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tracker.expireLocalResult()
        }
        expiryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        renderTracking()
        #endif
    }

    private func stop() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        guard isCapturing else { return }
        resetExpressions()
        emitPrediction(.cleared())
        isCapturing = false
        skeleton.path = nil
        tracker.pause()
        recognition.reset()
    }

    private func emit(_ status: String, handCount: Int = 0, message: String = "") {
        let key = "\(captureId):\(status):\(handCount):\(message)"
        guard key != lastStatus else { return }
        lastStatus = key
        onStatus(["captureId": captureId, "status": status, "handCount": handCount, "message": message])
        if status != "tracking" { sendPrediction(.cleared(), observedAtMS: Date().timeIntervalSince1970 * 1000) }
    }

    private func emitPrediction(_ prediction: BasicLivePrediction) {
        guard acceptsEvents else { return }
        guard prediction.phase != .cleared, let timestamp = prediction.timestampMS,
              timestamp >= captureStartedMS, recognition.ready,
              let frame = tracker.skeleton, frame.hasSigningPose, !frame.hands.isEmpty else {
            sendPrediction(.cleared(), observedAtMS: Date().timeIntervalSince1970 * 1000)
            return
        }
        let ageMS = CaptureClock.now * 1000 - Double(timestamp)
        guard ageMS >= 0, ageMS <= 1000 else {
            sendPrediction(.cleared(), observedAtMS: Date().timeIntervalSince1970 * 1000)
            return
        }
        renderTracking() // Publish readiness before the candidate on the same native queue.
        sendPrediction(prediction,
            observedAtMS: Date().timeIntervalSince1970 * 1000 - ageMS)
    }

    private func sendPrediction(_ prediction: BasicLivePrediction, observedAtMS: Double) {
        let candidates: [[String: Any]] = prediction.candidates.compactMap { score in
            guard let distance = score.measuredDistance else { return nil }
            return ["label": score.label, "distance": distance]
        }
        onPrediction(["captureId": captureId, "engine": "basic-temporal-v3",
                      "phase": prediction.phase.rawValue, "attemptId": prediction.attemptID as Any? ?? NSNull(),
                      "candidates": candidates, "label": prediction.label as Any? ?? NSNull(),
                      "matched": prediction.matched, "observedAtMS": observedAtMS,
                      "emotion": prediction.timestampMS.map { end in
                          expressions.history.emotion(from: prediction.startTimestampMS ?? end, through: end).rawValue
                      } ?? "neutral"])
    }

    private func renderTracking() {
        guard acceptsEvents else { return }
        if tracker.permissionDenied { skeleton.path = nil; emit("denied"); return }
        if let error = tracker.errorMessage { skeleton.path = nil; emit("error", message: error); return }
        guard tracker.isRunning else { skeleton.path = nil; emit("starting"); return }
        let frame = tracker.skeleton.flatMap { $0.timestampMS >= captureStartedMS ? $0 : nil }
        let path = UIBezierPath()
        if let frame {
            func points(_ source: [SkeletonPoint]) -> [Int: CGPoint] {
                var result: [Int: CGPoint] = [:]
                for point in source where point.usable {
                    let xy = SkeletonGeometry.project(point, width: Double(frame.width), height: Double(frame.height),
                        viewWidth: bounds.width, viewHeight: bounds.height, mirrored: tracker.isFront, aspectFill: false)
                    result[point.id] = CGPoint(x: xy.0, y: xy.1)
                }
                return result
            }
            func edge(_ a: Int, _ b: Int, in points: [Int: CGPoint]) {
                guard let a = points[a], let b = points[b] else { return }
                path.move(to: a); path.addLine(to: b)
            }
            for hand in frame.hands {
                let mapped = points(hand.points)
                for chain in SkeletonGeometry.handChains {
                    for (a, b) in zip(chain, chain.dropFirst()) { edge(a, b, in: mapped) }
                }
                for point in mapped.values {
                    path.append(UIBezierPath(ovalIn: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)))
                }
            }
            let body = points(frame.pose)
            for (a, b) in SkeletonGeometry.poseEdges where a >= 11 { edge(a, b, in: body) }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        skeleton.path = showSkeleton ? path.cgPath : nil
        CATransaction.commit()
        if let failure = recognition.loadFailure {
            emit(failure == .missing ? "references-missing" : "references-invalid", message: recognition.detail)
        } else if !recognition.ready {
            emit("recognizer-loading", message: recognition.detail)
        } else if let frame, !frame.hands.isEmpty {
            emit(frame.hasSigningPose ? "tracking" : "body-missing", handCount: frame.hands.count)
        } else { emit("searching") }
    }
}
