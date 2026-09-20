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
    let onSign = EventDispatcher()
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
            guard let self, self.isCapturing else { return }
            if self.labMode { return }
            if self.recognitionMode == "spelling" { self.alphabet.receive(frame) }
            else { self.recognition.receive(frame) }
            self.expression.observe(timestampMS: frame.timestampMS, hasFace: frame.hasFace,
                observation: ExpressionObservation.from(frame, measurement: self.expression.profile?.measurement ?? .current))
        }
        tracker.onSkeletonReset = { [weak self] in self?.resetRecognition() }
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
        let key = "\(captureId):\(recognitionMode):\(trackFace):\(labMode)"
        guard !isCapturing || key != appliedKey else { render(); return }
        isCapturing = false
        tracker.pause() // invalidates queued frames and both engines before changing epoch/mode
        appliedKey = key
        lastStatus = ""
        lastEmission = 0
        tracker.trackFace = trackFace || labMode
        expression = TaughtExpressionRuntime(profile: TaughtExpressionStore.standard.load())
        isCapturing = true
        emitStatus("starting")
        tracker.start()
        preview.mirrored = tracker.isFront
        preview.attach(session: tracker.session)
        preview.previewLayer.videoGravity = .resizeAspect
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tracker.expireLocalResult()
            self?.render()
        }
        #endif
    }
    private func stop() {
        timer?.invalidate(); timer = nil
        guard isCapturing else { return }
        isCapturing = false
        tracker.pause()
        skeleton.path = nil
        onSign(["captureId": captureId, "label": NSNull(), "observedAtMS": Date().timeIntervalSince1970 * 1000])
    }
    private func emitStatus(_ status: String, handCount: Int = 0, message: String = "") {
        let key = "\(captureId):\(status):\(handCount):\(message)"
        guard key != lastStatus else { return }
        lastStatus = key
        onStatus(["captureId": captureId, "status": status, "handCount": handCount, "message": message])
    }
    private func emitDetection(force: Bool = false) {
        let now = Date().timeIntervalSince1970 * 1000
        guard force || now-lastEmission >= 100 else { return }
        lastEmission = now
        let fresh = isCapturing && !labMode && tracker.skeleton != nil && tracker.isRunning
        let observed = now-Double(tracker.frameAgeMS ?? 1000)
        let label = fresh && recognitionMode == "signs" ? recognition.sign : nil
        onSign(["captureId": captureId, "label": label as Any? ?? NSNull(), "observedAtMS": observed])
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
        guard isCapturing else { return }
        if tracker.permissionDenied { emitStatus("denied"); emitDetection(); return }
        if let error = tracker.errorMessage { emitStatus("error", message: error); emitDetection(); return }
        guard tracker.isRunning else { emitStatus("starting"); emitDetection(); return }
        let frame = tracker.skeleton
        let count = frame?.hands.count ?? 0
        let usable = count > 0 && (recognitionMode == "spelling" || frame?.hasPose == true)
        emitStatus(usable ? "tracking" : "searching", handCount: count,
                   message: usable ? "" : "Keep hands and shoulders visible")
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
