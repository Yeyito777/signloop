import AVFoundation
import Combine
import ExpoModulesCore
import UIKit
import SwiftUI
import MediaPipeTasksVision

/// One camera and the SAME temporal/spelling engines as the standalone app.
/// Only decisions/diagnostics cross JS, never pixels or automatic frame uploads.
final class SignloopCameraView: ExpoView {
    let onStatus = EventDispatcher()
    let onPrediction = EventDispatcher()
    let onDetection = EventDispatcher()
    let onClose = EventDispatcher()
    let tracker: SkeletonCameraTracker
    let recognition = BasicLiveRecognition(activeLabels: BasicSignScore.presentationVocabulary,
                                           weMotionScale: BasicSignMatcher.compactWEMotionScale)
    let alphabet: AlphabetRecognition
    var active = false
    var captureId = 0
    var recognitionMode = "signs"
    var showSkeleton = true
    var showPose = true
    var trackFace = false
    var labMode = false
    private(set) var isCapturing = false
    private let preview = PreviewView()
    private let skeleton = CAShapeLayer()
    private var subscriptions = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var appliedKey = ""
    private var appliedCaptureId = -1
    private var captureStartedMS = 0
    private let missingModels: [String]
    private var timer: Timer?
    private var lastStatus = ""
    private var lastEmission = 0.0
    private var renderScheduled = false
    private var labHost: UIHostingController<ExpoExpressionLab>?
    private var expression = TaughtExpressionRuntime(profile: TaughtExpressionStore.standard.load())

    required init(appContext: AppContext? = nil) {
        let url = Bundle(for: SignloopCameraView.self).url(forResource: "SignloopCameraModels", withExtension: "bundle")
            ?? Bundle.main.url(forResource: "SignloopCameraModels", withExtension: "bundle")
        let bundle = url.flatMap(Bundle.init(url:)) ?? .main
        missingModels = ["hand_landmarker", "pose_landmarker_lite"].filter {
            bundle.path(forResource: $0, ofType: "task") == nil
        }
        tracker = SkeletonCameraTracker(modelBundle: bundle)
        alphabet = AlphabetRecognition(modelURL: bundle.url(forResource: "alphabet-static", withExtension: "json"),
                                       allowedLetters: AlphabetModel.aurelioLetters)
        super.init(appContext: appContext)
        clipsToBounds = true
        backgroundColor = .black
        preview.attach(session: tracker.session)
        // Keep hands AND chest visible inside Expo's wide camera region.
        preview.previewLayer.videoGravity = .resizeAspect
        addSubview(preview)
        skeleton.fillColor = UIColor.clear.cgColor
        skeleton.strokeColor = UIColor(red: 1, green: 0.95, blue: 0.73, alpha: 1).cgColor
        skeleton.lineWidth = 2
        skeleton.lineCap = .round
        layer.addSublayer(skeleton)
        tracker.onSkeletonFrame = { [weak self] frame in
            guard let self, self.acceptsEvents, frame.timestampMS >= self.captureStartedMS else { return }
            if self.labMode { return }
            if self.recognitionMode == "spelling" { self.alphabet.receive(frame) }
            else { self.recognition.receive(frame) }
            self.expression.observe(timestampMS: frame.timestampMS, hasFace: frame.hasFace,
                observation: ExpressionObservation.from(frame, measurement: self.expression.profile?.measurement ?? .current))
        }
        tracker.onSkeletonReset = { [weak self] in self?.resetRecognition() }
        recognition.onPrediction = { [weak self] in self?.emitPrediction($0) }
        for publisher in [tracker.objectWillChange, recognition.objectWillChange, alphabet.objectWillChange] {
            publisher.sink { [weak self] _ in self?.scheduleRender() }.store(in: &subscriptions)
        }
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.stop() })
        }
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.synchronize() })
        recognition.load()
        alphabet.load()
    }

    deinit {
        timer?.invalidate()
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
        labHost?.view.frame = bounds
        render()
    }
    private func resetRecognition() {
        recognition.reset()
        alphabet.reset()
        expression.resetTracking()
    }
    private var acceptsEvents: Bool { active && isCapturing && appliedCaptureId == captureId }
    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.renderScheduled = false
            self?.render()
        }
    }
    func synchronize() {
        guard active, window != nil, UIApplication.shared.applicationState == .active else { stop(); return }
        if labMode && labHost == nil {
            let host = UIHostingController(rootView: ExpoExpressionLab(tracker: tracker, onDone: { [weak self] in self?.onClose([:]) }))
            // Expo provides the containing view controller once mounted.
            var responder: UIResponder? = self
            while let next = responder, !(next is UIViewController) { responder = next.next }
            if let parent = responder as? UIViewController { parent.addChild(host) }
            addSubview(host.view)
            host.view.frame = bounds
            host.didMove(toParent: host.parent)
            labHost = host
        } else if !labMode, let host = labHost {
            host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent(); labHost = nil
        }
        #if targetEnvironment(simulator)
        emitStatus("unavailable", message: "Camera recognition needs a physical iPhone.")
        emitDetection(force: true)
        return
        #else
        guard missingModels.isEmpty else {
            emitStatus("model-missing", message: "Missing tracking models. Rebuild the app.")
            return
        }
        let key = "\(recognitionMode):\(trackFace):\(labMode)"
        guard !isCapturing || key != appliedKey || appliedCaptureId != captureId else { render(); return }
        let restartCamera = !isCapturing || key != appliedKey
        isCapturing = false
        if restartCamera { tracker.pause() }
        resetRecognition()
        appliedKey = key
        appliedCaptureId = captureId
        captureStartedMS = Int(CaptureClock.now * 1000)
        lastStatus = ""
        lastEmission = 0
        tracker.trackFace = trackFace || labMode
        expression = TaughtExpressionRuntime(profile: TaughtExpressionStore.standard.load())
        isCapturing = true
        recognition.load() // Allows Retry after provisioning references.
        emitStatus("starting")
        if restartCamera { tracker.start() }
        preview.mirrored = tracker.isFront
        preview.attach(session: tracker.session)
        preview.previewLayer.videoGravity = .resizeAspect
        timer?.invalidate()
        let nextTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tracker.expireLocalResult()
            self?.render()
        }
        timer = nextTimer
        RunLoop.main.add(nextTimer, forMode: .common)
        #endif
    }
    private func stop() {
        timer?.invalidate(); timer = nil
        guard isCapturing else { return }
        sendPrediction(.cleared(), observedAtMS: Date().timeIntervalSince1970 * 1000)
        isCapturing = false
        tracker.pause()
        skeleton.path = nil
    }
    private func emitStatus(_ status: String, handCount: Int = 0, message: String = "") {
        let key = "\(captureId):\(status):\(handCount):\(message)"
        guard key != lastStatus else { return }
        lastStatus = key
        onStatus(["captureId": captureId, "status": status, "handCount": handCount, "message": message])
        if status != "tracking" { sendPrediction(.cleared(), observedAtMS: Date().timeIntervalSince1970 * 1000) }
    }
    private func emitPrediction(_ prediction: BasicLivePrediction) {
        guard acceptsEvents, recognitionMode == "signs", !labMode else { return }
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
        render() // Readiness must precede a candidate on the same native queue.
        sendPrediction(prediction, observedAtMS: Date().timeIntervalSince1970 * 1000 - ageMS)
    }
    private func sendPrediction(_ prediction: BasicLivePrediction, observedAtMS: Double) {
        let candidates: [[String: Any]] = prediction.candidates.compactMap { score in
            guard let distance = score.measuredDistance else { return nil }
            return ["label": score.label, "distance": distance]
        }
        onPrediction(["captureId": captureId, "engine": "basic-temporal-v3",
                      "phase": prediction.phase.rawValue, "attemptId": prediction.attemptID as Any? ?? NSNull(),
                      "candidates": candidates, "label": prediction.label as Any? ?? NSNull(),
                      "matched": prediction.matched, "observedAtMS": observedAtMS])
    }
    private func emitDetection(force: Bool = false) {
        let now = Date().timeIntervalSince1970 * 1000
        guard force || now-lastEmission >= 100 else { return }
        lastEmission = now
        let fresh = acceptsEvents && !labMode && tracker.isRunning
            && (tracker.skeleton?.timestampMS ?? -1) >= captureStartedMS
        let observed = now-Double(tracker.frameAgeMS ?? 1000)
        let label = fresh && recognitionMode == "signs" ? recognition.sign : nil
        onDetection([
            "captureId": captureId, "mode": recognitionMode, "observedAtMS": observed,
            "letter": (fresh && recognitionMode == "spelling" ? alphabet.letter : nil) as Any? ?? NSNull(),
            "label": label as Any? ?? NSNull(), "ready": recognitionMode == "spelling" ? alphabet.ready : recognition.ready,
            "detail": recognitionMode == "spelling" ? alphabet.detail : recognition.detail,
            "fps": tracker.fps, "trackingMS": tracker.latencyMS,
            "matchMS": recognitionMode == "spelling" ? alphabet.matchMS : recognition.matchMS,
            "expression": expression.profile != nil && fresh && tracker.trackFace ? expression.result.title : "",
            "scores": recognition.scores.map { row in
                ["label": row.label, "distance": (fresh ? row.distance : nil) as Any? ?? NSNull()] as [String: Any]
            }
        ])
    }
    private func render() {
        #if targetEnvironment(simulator)
        if active { emitDetection() }
        #endif
        guard acceptsEvents else { return }
        if tracker.permissionDenied { emitStatus("denied"); emitDetection(); return }
        if let error = tracker.errorMessage { emitStatus("error", message: error); emitDetection(); return }
        guard tracker.isRunning else { emitStatus("starting"); emitDetection(); return }
        let frame = tracker.skeleton.flatMap { $0.timestampMS >= captureStartedMS ? $0 : nil }
        let count = frame?.hands.count ?? 0
        if recognitionMode == "signs" && !labMode, let failure = recognition.loadFailure {
            emitStatus(failure == .missing ? "references-missing" : "references-invalid", message: recognition.detail)
        } else if recognitionMode == "signs" && !labMode && !recognition.ready {
            emitStatus("recognizer-loading", message: recognition.detail)
        } else {
            let status = count == 0 ? "searching"
                : recognitionMode == "spelling" || frame?.hasSigningPose == true ? "tracking" : "body-missing"
            emitStatus(status, handCount: count)
        }
        let path = UIBezierPath()
        if let frame {
            let scale = min(bounds.width / CGFloat(frame.width), bounds.height / CGFloat(frame.height))
            func point(_ p: SkeletonPoint) -> CGPoint {
                CGPoint(x: (bounds.width-CGFloat(frame.width)*scale)/2 + CGFloat(tracker.isFront ? 1-p.x : p.x)*CGFloat(frame.width)*scale,
                        y: (bounds.height-CGFloat(frame.height)*scale)/2 + CGFloat(p.y)*CGFloat(frame.height)*scale)
            }
            func draw(_ points: [SkeletonPoint], _ edges: [(Int, Int)]) {
                let valid = Dictionary(uniqueKeysWithValues: points.filter(\.usable).map { ($0.id, $0) })
                for (a,b) in edges {
                    if let p = valid[a], let q = valid[b] { path.move(to: point(p)); path.addLine(to: point(q)) }
                }
            }
            if showSkeleton {
                for hand in frame.hands { draw(hand.points, SkeletonGeometry.handChains.flatMap { Array(zip($0, $0.dropFirst())) }) }
            }
            if showPose { draw(frame.pose, SkeletonGeometry.poseEdges) }
            if trackFace { draw(frame.face, FaceLandmarker.contoursConnections().map { (Int($0.start), Int($0.end)) }) }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true); skeleton.path = path.cgPath; CATransaction.commit()
        emitDetection()
    }
}

private struct ExpoExpressionLab: View {
    @ObservedObject var tracker: SkeletonCameraTracker
    var onDone: () -> Void
    @State private var runtime = TaughtExpressionRuntime(profile: TaughtExpressionStore.standard.load())
    @State private var paused = false
    var body: some View {
        ExpressionTesterView(tracker: tracker, runtime: $runtime, paused: $paused, onDone: onDone)
            .onReceive(tracker.$skeleton) { frame in
                guard let frame, !paused else { runtime.resetTracking(); return }
                runtime.observe(timestampMS: frame.timestampMS, hasFace: frame.hasFace,
                    observation: ExpressionObservation.from(frame, measurement: runtime.profile?.measurement ?? .current))
            }
    }
}
