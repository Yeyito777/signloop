import AVFoundation
import Combine
import MediaPipeTasksVision
import UIKit

/// Session configuration and inference are serialized on a non-main queue.
/// UI state is published exclusively on the main queue.
final class CameraTracker: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    @Published private(set) var hands: [TrackedHand] = []
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
    @Published private(set) var localSign: String?
    @Published var showJoints = UserDefaults.standard.bool(forKey: "showHandJoints") {
        didSet { UserDefaults.standard.set(showJoints, forKey: "showHandJoints") }
    }
    @Published var showNumbers = UserDefaults.standard.bool(forKey: "showJointNumbers") {
        didSet { UserDefaults.standard.set(showNumbers, forKey: "showJointNumbers") }
    }
    @Published private(set) var snapshotURL: URL?
    // Main-thread callbacks; frames stay in RAM on the phone.
    var onFrame: ((LandmarkFrame) -> Void)?
    var onReset: (() -> Void)?
    /// Sign predictions from the on-device SignEngine (main queue). Nil unless a cleared model
    /// package is bundled; see recognition/export_coreml.py. Never carries landmarks.
    var onPrediction: ((SignPrediction) -> Void)?
    private var uiGeneration = 0
    private var captureGeneration = 0 // camera queue only
    private var wantsRunning = false

    private let queue = DispatchQueue(label: "com.signloop.camera", qos: .userInitiated)
    private var recognizer: GestureRecognizer?
    private var localFilter = LocalGestureFilter()
    private var displayLifetime = CaptureDisplayLifetime() // main queue only
    private var configured = false
    private var front = true
    private var freshness = CaptureFreshness()
    private var cadence = CaptureCadence()
    private var rateStart = 0.0
    private var rateFrames = 0
    private var buffer = TemporalBuffer()
    private var observers: [NSObjectProtocol] = []
    private let lifecycle = CaptureLifecycle()
    private let modelPath: String?
    private let signEngineDirectory: URL?
    private var signEngine: SignEngine? // camera queue only

    init(modelPath: String? = Bundle.main.path(forResource: "gesture_recognizer", ofType: "task"),
         signEngineDirectory: URL? = SignEngine.locate(in: .main)) {
        self.modelPath = modelPath
        self.signEngineDirectory = signEngineDirectory
        super.init()
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionWasInterrupted, object: session, queue: .main
        ) { [weak self] _ in
            self?.invalidateDisplayedFrames()
            if let self { self.queue.async { self.localFilter.reset(); self.signEngine?.reset() } }
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
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            self.isRunning = false
            self.invalidateDisplayedFrames()
            self.errorMessage = error?.localizedDescription ?? "Camera error. Tap Resume to retry."
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private func invalidateDisplayedFrames() {
        uiGeneration += 1
        hands = []
        localSign = nil
        frameAgeMS = nil
        displayLifetime.reset()
        onReset?()
    }

    func start() {
        wantsRunning = true
        invalidateDisplayedFrames()
        requestStart(token: lifecycle.begin())
    }

    private func requestStart(token: Int) {
        guard lifecycle.accepts(token) else { return }
        let generation = uiGeneration
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permissionDenied = false
            errorMessage = nil
            queue.async { self.startOnQueue(token: token, generation: generation) }
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
        invalidateDisplayedFrames()
        let generation = uiGeneration
        isRunning = false
        queue.async {
            self.session.stopRunning()
            self.buffer.reset()
            self.localFilter.reset()
            self.signEngine?.reset()
            self.cadence.reset()
            self.recognizer = nil
            DispatchQueue.main.async {
                guard self.lifecycle.token == nil, self.uiGeneration == generation else { return }
                self.isRunning = false
                self.hands = []
                self.localSign = nil
                self.bufferedFrames = 0
                self.fps = 0
                self.latencyMS = 0
                self.status = "Camera paused"
            }
        }
    }

    func flipCamera() {
        invalidateDisplayedFrames()
        let generation = uiGeneration
        queue.async {
            guard self.configured else { return }
            self.captureGeneration = generation
            let wasRunning = self.session.isRunning
            self.session.stopRunning()
            do {
                try self.replaceInput(front: !self.front)
                self.buffer.reset()
                self.localFilter.reset()
                self.signEngine?.reset()
                self.cadence.reset()
                self.rateStart = CACurrentMediaTime()
                self.rateFrames = 0
                self.recognizer = nil
                try self.configureRecognizer()
                self.freshness.reset(at: CaptureClock.now)
                if wasRunning { self.session.startRunning() }
                let nowFront = self.front
                DispatchQueue.main.async {
                    guard self.uiGeneration == generation else { return }
                    self.isFront = nowFront
                    self.hands = []
                    self.localSign = nil
                    self.bufferedFrames = 0
                    self.status = wasRunning ? "Looking for hands" : "Camera paused"
                }
            } catch { self.report(error) }
        }
    }

    func exportLandmarks() {
        queue.async {
            guard !self.buffer.frames.isEmpty else { return }
            struct Export: Encodable {
                let schemaVersion = 1
                let tracker = "MediaPipe Gesture Recognizer / hand landmarks 0.10.21"
                let coordinateSpace = "portrait mirrored for front camera; normalized image x,y; relative z"
                let camera: String
                let frames: [LandmarkFrame]
                let normalizedHands: [[[Joint]]]
            }
            do {
                let frames = self.buffer.frames
                let payload = Export(camera: self.front ? "front" : "back", frames: frames,
                                     normalizedHands: frames.map { $0.hands.map(\.normalized) })
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("honk-and-tell-landmarks.json")
                try encoder.encode(payload).write(to: url, options: .atomic)
                DispatchQueue.main.async { self.snapshotURL = url }
            } catch { self.report(error) }
        }
    }

    func clearExport() { snapshotURL = nil }

    /// Main-thread watchdog; a stalled camera cannot leave an old sign visible.
    func expireLocalResult() {
        guard displayLifetime.expire(now: CaptureClock.now) else { return }
        hands = []
        localSign = nil
        frameAgeMS = nil
        bufferedFrames = 0
        fps = 0
        latencyMS = 0
        onReset?()
        if isRunning && wantsRunning { status = "Waiting for fresh camera frames" }
    }

    func recentFrames() async -> [LandmarkFrame] {
        await withCheckedContinuation { continuation in
            queue.async {
                let cutoff = (self.buffer.frames.last?.timestampMS ?? 0) - 1200
                continuation.resume(returning: self.buffer.frames.filter { $0.timestampMS >= cutoff })
            }
        }
    }

    private func configureRecognizer() throws {
        if recognizer == nil {
            guard let model = modelPath else {
                throw TrackerError.message("Missing hand model. Run ios/scripts/bootstrap.sh and rebuild.")
            }
            let options = GestureRecognizerOptions()
            options.baseOptions.modelAssetPath = model
            options.runningMode = .video
            options.numHands = 2
            options.minHandDetectionConfidence = 0.55
            options.minHandPresenceConfidence = 0.55
            options.minTrackingConfidence = 0.55
            let classifier = ClassifierOptions()
            classifier.maxResults = 2
            options.cannedGesturesClassifierOptions = classifier
            recognizer = try GestureRecognizer(options: options)
        }
    }

    /// Optional. A missing, uncleared or incompatible package simply leaves the engine off; the
    /// ILY handshape path is unaffected.
    private func loadSignEngineIfAvailable() {
        guard signEngine == nil, let directory = signEngineDirectory,
              let engine = try? SignEngine.load(directory: directory) else { return }
        engine.onPrediction = { [weak self] prediction in
            DispatchQueue.main.async {
                guard let self, self.wantsRunning else { return }
                self.onPrediction?(prediction)
            }
        }
        signEngine = engine
    }

    private func startOnQueue(token: Int, generation: Int) {
        guard lifecycle.accepts(token) else { return }
        captureGeneration = generation
        do {
            try configureRecognizer()
            loadSignEngineIfAvailable()
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
                    throw TrackerError.message("Camera video output is unavailable.")
                }
                session.addOutput(output)
                configureOutputConnection()
                configured = true
            }
            buffer.reset()
            localFilter.reset()
            signEngine?.reset()
            cadence.reset()
            rateStart = CACurrentMediaTime()
            rateFrames = 0
            guard lifecycle.accepts(token) else { return }
            freshness.reset(at: CaptureClock.now)
            session.startRunning()
            guard lifecycle.accepts(token) else { session.stopRunning(); return }
            let running = session.isRunning
            DispatchQueue.main.async {
                guard self.lifecycle.accepts(token), self.uiGeneration == generation else { return }
                self.errorMessage = nil
                self.isRunning = running
                self.status = running ? "Looking for hands" : "Camera unavailable"
            }
        } catch { report(error, token: token) }
    }

    private func replaceInput(front useFront: Bool) throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video,
                                                   position: useFront ? .front : .back) else {
            throw TrackerError.message("This camera isn't available.")
        }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        let previous = session.inputs
        previous.forEach { session.removeInput($0) }
        guard session.canAddInput(input) else {
            previous.forEach { if session.canAddInput($0) { session.addInput($0) } }
            throw TrackerError.message("Couldn't switch camera.")
        }
        session.addInput(input)
        front = useFront
        try device.lockForConfiguration()
        if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
        }
        device.unlockForConfiguration()
        configureOutputConnection()
    }

    private func configureOutputConnection() {
        for output in session.outputs {
            guard let connection = output.connection(with: .video) else { continue }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = front
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard session.isRunning, let recognizer, let token = lifecycle.token else { return }
        let now = CACurrentMediaTime()
        let generation = captureGeneration
        guard let captured = CaptureClock.hostSeconds(
            presentation: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            sourceClock: session.synchronizationClock),
              let timestamp = freshness.timestamp(captured: captured, now: CaptureClock.now) else {
            buffer.reset()
            localFilter.reset()
            signEngine?.reset()
            DispatchQueue.main.async {
                guard self.uiGeneration == generation, self.wantsRunning else { return }
                self.hands = []
                self.localSign = nil
                self.frameAgeMS = nil
                self.displayLifetime.reset()
                self.bufferedFrames = 0
                self.onReset?()
                self.status = "Waiting for fresh camera frames"
            }
            return
        }
        guard cadence.admit(at: captured) else { return }
        do {
            // Pixel buffers are physically rotated/mirrored by the output connection.
            let image = try MPImage(sampleBuffer: sampleBuffer, orientation: .up)
            let result = try recognizer.recognize(videoFrame: image, timestampInMilliseconds: timestamp)
            let elapsed = Int((CACurrentMediaTime() - now) * 1000)
            let detected = result.landmarks.enumerated().map { index, landmarks in
                let category = result.handedness[safe: index]?.first
                return TrackedHand(handedness: category?.categoryName ?? "Hand",
                                   handednessScore: category?.score ?? 0,
                                   joints: landmarks.map { Joint(x: $0.x, y: $0.y, z: $0.z) })
            }
            let gestures = result.gestures.map { categories -> LocalHandGesture in
                let ranked = categories.sorted { $0.score > $1.score }
                return LocalHandGesture(label: ranked.first?.categoryName ?? "None",
                                        score: ranked.first?.score ?? 0,
                                        runner: ranked.dropFirst().first?.score ?? 0)
            }
            let local = localFilter.update(gestures.count == detected.count ? gestures : [],
                                           timestampMS: timestamp)
            let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            let width = pixelBuffer.map { CVPixelBufferGetWidth($0) } ?? 720
            let height = pixelBuffer.map { CVPixelBufferGetHeight($0) } ?? 1280
            let frame = LandmarkFrame(timestampMS: timestamp, hands: detected,
                                      imageAspectRatio: Float(width) / Float(height),
                                      mirrored: connection.isVideoMirrored)
            buffer.append(frame)
            signEngine?.receive(frame)
            let count = buffer.frames.count
            rateFrames += 1
            var measuredFPS: Int?
            if now - rateStart >= 1 {
                measuredFPS = Int(Double(rateFrames) / (now - rateStart))
                rateStart = now
                rateFrames = 0
            }
            DispatchQueue.main.async {
                guard self.lifecycle.accepts(token) else { return }
                guard self.uiGeneration == generation, self.wantsRunning else { return }
                let deliveredAt = CaptureClock.now
                let age = deliveredAt - captured
                let fresh = CaptureFreshness.isFresh(captured: captured, now: deliveredAt)
                self.hands = fresh ? detected : []
                self.localSign = fresh ? local : nil
                self.frameAgeMS = fresh ? Int(age*1000) : nil
                if fresh { self.displayLifetime.received(at: captured) }
                else { self.displayLifetime.reset() }
                if fresh { self.onFrame?(frame) } else { self.onReset?() }
                self.latencyMS = elapsed
                self.bufferedFrames = count
                self.frameSize = CGSize(width: width, height: height)
                if let measuredFPS { self.fps = measuredFPS }
                self.status = !fresh ? "Waiting for fresh camera frames" :
                    detected.isEmpty ? "Looking for hands" : "Tracking \(detected.count) \(detected.count == 1 ? "hand" : "hands")"
            }
        } catch { report(error, token: token) }
    }

    private func report(_ error: Error, token: Int? = nil) {
        if let token, !lifecycle.accepts(token) { return }
        localFilter.reset()
        let generation = captureGeneration
        // Called on the capture queue: do not enqueue a stop behind a newer start.
        if session.isRunning { session.stopRunning() }
        DispatchQueue.main.async {
            if let token, !self.lifecycle.accepts(token) { return }
            guard self.uiGeneration == generation else { return }
            self.invalidateDisplayedFrames()
            self.isRunning = false
            self.errorMessage = error.localizedDescription
            self.status = "Tracking unavailable"
        }
    }
}

private enum TrackerError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
