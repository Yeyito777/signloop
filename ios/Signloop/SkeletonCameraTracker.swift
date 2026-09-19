import AVFoundation
import Combine
import MediaPipeTasksVision
import UIKit

/// Capture + three synchronized detectors on one serial queue. Late camera
/// frames are dropped rather than queued. Published state is main-thread-only.
final class SkeletonCameraTracker: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    @Published private(set) var skeleton: SkeletonFrame?
    @Published private(set) var status = "Starting camera…"
    @Published private(set) var isRunning = false
    @Published private(set) var isFront = true
    @Published private(set) var permissionDenied = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var latencyMS = 0
    @Published private(set) var frameAgeMS: Int?
    @Published private(set) var fps = 0
    @Published private(set) var bufferedFrames = 0
    @Published private(set) var frameSize = CGSize(width: 720, height: 1280)
    // New tracking-only defaults: visible skeleton, independent of old sign UI.
    @Published var showJoints = UserDefaults.standard.object(forKey: "skeletonHands") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showJoints, forKey: "skeletonHands") }
    }
    @Published var showPose = UserDefaults.standard.object(forKey: "skeletonPose") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showPose, forKey: "skeletonPose") }
    }
    @Published var showFace = UserDefaults.standard.object(forKey: "skeletonFace") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showFace, forKey: "skeletonFace") }
    }
    @Published var trackFace = UserDefaults.standard.bool(forKey: "experimentalFaceTracking") {
        didSet {
            UserDefaults.standard.set(trackFace, forKey: "experimentalFaceTracking")
            if wantsRunning { start() }
        }
    }
    @Published var showNumbers = UserDefaults.standard.bool(forKey: "showJointNumbers") {
        didSet { UserDefaults.standard.set(showNumbers, forKey: "showJointNumbers") }
    }
    /// Optional in-process consumers only. No automatic storage or transport.
    var onSkeletonFrame: ((SkeletonFrame) -> Void)?
    var onSkeletonReset: (() -> Void)?
    private(set) var probeBuffer = SkeletonBuffer() // main thread only

    private let queue = DispatchQueue(label: "com.signloop.camera", qos: .userInitiated)
    private var pipeline: SkeletonPipeline?
    private var faceEnabledOnQueue = false
    private var configured = false
    private var front = true
    private var uiGeneration = 0
    private var captureGeneration = 0
    private var wantsRunning = false
    private var freshness = CaptureFreshness()
    private var cadence = CaptureCadence(targetFPS: 15)
    private var displayLifetime = CaptureDisplayLifetime()
    private var rateStart = 0.0
    private var rateFrames = 0
    private var observers: [NSObjectProtocol] = []
    private let lifecycle = CaptureLifecycle()

    override init() {
        super.init()
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionWasInterrupted, object: session, queue: .main
        ) { [weak self] _ in
            self?.invalidate()
            self?.isRunning = false
            self?.status = "Camera interrupted"
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionInterruptionEnded, object: session, queue: .main
        ) { [weak self] _ in
            guard let self, let token = self.lifecycle.token else { return }
            self.requestStart(token: token)
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError, object: session, queue: .main
        ) { [weak self] notification in
            guard let self, self.lifecycle.token != nil else { return }
            self.invalidate()
            self.isRunning = false
            self.errorMessage = (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)?
                .localizedDescription ?? "Camera error. Tap Resume to retry."
        })
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private func clearFrame() {
        onSkeletonReset?()
        skeleton = nil
        frameAgeMS = nil
        fps = 0
        latencyMS = 0
        bufferedFrames = 0
        probeBuffer.reset()
        displayLifetime.reset()
    }

    private func invalidate() { uiGeneration += 1; clearFrame() }

    func start() {
        wantsRunning = true
        invalidate()
        isRunning = false
        errorMessage = nil
        status = "Starting trackers…"
        requestStart(token: lifecycle.begin())
    }

    private func requestStart(token: Int) {
        guard lifecycle.accepts(token) else { return }
        let generation = uiGeneration
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permissionDenied = false
            let useFace = trackFace
            queue.async {
                guard self.lifecycle.accepts(token) else { return }
                self.faceEnabledOnQueue = useFace
                self.startOnQueue(token: token, generation: generation)
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                DispatchQueue.main.async { self?.requestStart(token: token) }
            }
        default:
            permissionDenied = true
            status = "Camera access needed"
        }
    }

    func pause() {
        lifecycle.end()
        wantsRunning = false
        invalidate()
        isRunning = false
        status = "Camera paused"
        queue.async {
            self.session.stopRunning()
            self.pipeline = nil
            self.cadence.reset()
        }
    }

    func flipCamera() {
        guard isRunning, let token = lifecycle.token else { return }
        invalidate()
        isRunning = false
        status = "Switching camera…"
        let generation = uiGeneration
        queue.async {
            guard self.lifecycle.accepts(token) else { return }
            self.captureGeneration = generation
            self.session.stopRunning()
            do {
                try self.replaceInput(front: !self.front)
                self.startOnQueue(token: token, generation: generation)
            } catch { self.report(error, token: token, generation: generation) }
        }
    }

    /// Called by a main-thread timer; stale face, expression and body disappear
    /// together even if capture stalls completely.
    func expireLocalResult() {
        guard displayLifetime.expire(now: CaptureClock.now) else { return }
        clearFrame()
        if isRunning && wantsRunning { status = "Waiting for fresh camera frames" }
    }

    private func startOnQueue(token: Int, generation: Int) {
        guard lifecycle.accepts(token) else { return }
        captureGeneration = generation
        do {
            if session.isRunning { session.stopRunning() }
            pipeline = nil
            pipeline = try SkeletonPipeline(trackFace: faceEnabledOnQueue)
            if !configured {
                session.beginConfiguration()
                session.sessionPreset = .hd1280x720
                session.commitConfiguration()
                try replaceInput(front: front)
                let output = AVCaptureVideoDataOutput()
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: queue)
                guard session.canAddOutput(output) else {
                    throw SkeletonTrackerError.message("Camera video output is unavailable.")
                }
                session.addOutput(output)
                configureOutputConnection()
                configured = true
            }
            cadence.reset()
            rateStart = CACurrentMediaTime()
            rateFrames = 0
            guard lifecycle.accepts(token) else { return }
            freshness.reset(at: CaptureClock.now)
            session.startRunning()
            guard lifecycle.accepts(token) else { session.stopRunning(); return }
            let running = session.isRunning
            let facing = front
            DispatchQueue.main.async {
                guard self.lifecycle.accepts(token), self.uiGeneration == generation, self.wantsRunning else { return }
                self.errorMessage = nil
                self.isRunning = running
                self.isFront = facing
                self.status = running ? "Frame your face, hands and waist" : "Camera unavailable"
            }
        } catch { report(error, token: token, generation: generation) }
    }

    private func replaceInput(front useFront: Bool) throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video,
                                                   position: useFront ? .front : .back) else {
            throw SkeletonTrackerError.message("This camera isn't available.")
        }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        let previous = session.inputs
        previous.forEach { session.removeInput($0) }
        guard session.canAddInput(input) else {
            previous.forEach { if session.canAddInput($0) { session.addInput($0) } }
            throw SkeletonTrackerError.message("Couldn't switch camera.")
        }
        session.addInput(input)
        front = useFront
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
        }
        configureOutputConnection()
    }

    private func configureOutputConnection() {
        for output in session.outputs {
            guard let connection = output.connection(with: .video) else { continue }
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                // Canonical input never mirrors. Only the selfie preview/overlay do.
                connection.isVideoMirrored = false
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard session.isRunning, let pipeline, let token = lifecycle.token else { return }
        let generation = captureGeneration
        guard let captured = CaptureClock.hostSeconds(
            presentation: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            sourceClock: session.synchronizationClock),
              let timestamp = freshness.timestamp(captured: captured, now: CaptureClock.now) else {
            DispatchQueue.main.async {
                guard self.lifecycle.accepts(token), self.uiGeneration == generation, self.wantsRunning else { return }
                self.clearFrame()
                self.status = "Waiting for fresh camera frames"
            }
            return
        }
        guard cadence.admit(at: captured),
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        do {
            let image = try MPImage(sampleBuffer: sampleBuffer, orientation: .up)
            let frame = try pipeline.detect(image, timestampMS: timestamp,
                width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels),
                camera: front ? "front" : "back")
            let now = CACurrentMediaTime()
            rateFrames += 1
            var measuredFPS: Int?
            if now-rateStart >= 1 {
                measuredFPS = Int(Double(rateFrames)/(now-rateStart))
                rateStart = now
                rateFrames = 0
            }
            DispatchQueue.main.async {
                guard self.lifecycle.accepts(token), self.uiGeneration == generation, self.wantsRunning else { return }
                let delivered = CaptureClock.now
                guard CaptureFreshness.isFresh(captured: captured, now: delivered) else {
                    self.clearFrame()
                    self.status = "Waiting for fresh camera frames"
                    return
                }
                self.skeleton = frame
                self.displayLifetime.received(at: captured)
                self.frameAgeMS = Int((delivered-captured)*1000)
                self.latencyMS = Int(frame.timingsMS["total"] ?? 0)
                self.probeBuffer.append(frame)
                self.bufferedFrames = self.probeBuffer.frames.count
                self.frameSize = CGSize(width: frame.width, height: frame.height)
                if let measuredFPS { self.fps = measuredFPS }
                self.status = frame.hasPose && !frame.hands.isEmpty
                    ? (self.trackFace ? "Tracking hands, body and face" : "Tracking hands and upper body · face off")
                    : "Keep your hands, shoulders and chest in view"
                self.onSkeletonFrame?(frame)
            }
        } catch { report(error, token: token, generation: generation) }
    }

    private func report(_ error: Error, token: Int, generation: Int) {
        guard lifecycle.accepts(token) else { return }
        session.stopRunning()
        pipeline = nil
        DispatchQueue.main.async {
            guard self.lifecycle.accepts(token), self.uiGeneration == generation else { return }
            self.invalidate()
            self.isRunning = false
            self.errorMessage = error.localizedDescription
            self.status = "Tracking unavailable"
        }
    }
}

private enum SkeletonTrackerError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
