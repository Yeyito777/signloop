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
    private var uiGeneration = 0
    private var captureGeneration = 0 // camera queue only
    private var wantsRunning = false

    private let queue = DispatchQueue(label: "com.signloop.camera", qos: .userInitiated)
    private var recognizer: GestureRecognizer?
    private var localFilter = LocalGestureFilter()
    private var lastLocalFrameAt: CFTimeInterval = 0
    private var configured = false
    private var front = true
    private var freshness = CaptureFreshness()
    private var cadence = CaptureCadence()
    private var rateStart = 0.0
    private var rateFrames = 0
    private var buffer = TemporalBuffer()
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionWasInterrupted, object: session, queue: .main
        ) { [weak self] _ in
            self?.invalidateDisplayedFrames()
            if let self { self.queue.async { self.localFilter.reset() } }
            self?.isRunning = false
            self?.status = "Camera interrupted"
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionInterruptionEnded, object: session, queue: .main
        ) { [weak self] _ in
            if self?.wantsRunning == true { self?.start() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError, object: session, queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            self?.isRunning = false
            self?.invalidateDisplayedFrames()
            self?.errorMessage = error?.localizedDescription ?? "Camera error. Tap Resume to retry."
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private func invalidateDisplayedFrames() {
        uiGeneration += 1
        hands = []
        localSign = nil
        frameAgeMS = nil
        onReset?()
    }

    func start() {
        wantsRunning = true
        invalidateDisplayedFrames()
        let generation = uiGeneration
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permissionDenied = false
            queue.async { self.startOnQueue(generation: generation) }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                DispatchQueue.main.async {
                    if self?.wantsRunning == true { self?.start() }
                }
            }
        default:
            permissionDenied = true
            status = "Camera access needed"
        }
    }

    func pause() {
        wantsRunning = false
        invalidateDisplayedFrames()
        let generation = uiGeneration
        isRunning = false
        queue.async {
            self.session.stopRunning()
            self.buffer.reset()
            self.localFilter.reset()
            self.cadence.reset()
            self.recognizer = nil
            DispatchQueue.main.async {
                guard self.uiGeneration == generation else { return }
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
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("signloop-landmarks.json")
                try encoder.encode(payload).write(to: url, options: .atomic)
                DispatchQueue.main.async { self.snapshotURL = url }
            } catch { self.report(error) }
        }
    }

    func clearExport() { snapshotURL = nil }

    /// Main-thread watchdog; a stalled camera cannot leave an old sign visible.
    func expireLocalResult() {
        if CaptureClock.now - lastLocalFrameAt > 0.4 {
            localSign = nil
            frameAgeMS = nil
        }
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
            guard let model = Bundle.main.path(forResource: "gesture_recognizer", ofType: "task") else {
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

    private func startOnQueue(generation: Int) {
        captureGeneration = generation
        do {
            try configureRecognizer()
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
            cadence.reset()
            rateStart = CACurrentMediaTime()
            rateFrames = 0
            freshness.reset(at: CaptureClock.now)
            session.startRunning()
            let running = session.isRunning
            DispatchQueue.main.async {
                guard self.uiGeneration == generation else { return }
                self.errorMessage = nil
                self.isRunning = running
                self.status = running ? "Looking for hands" : "Camera unavailable"
            }
        } catch { report(error) }
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
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = front
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard session.isRunning, let recognizer else { return }
        let now = CACurrentMediaTime()
        let generation = captureGeneration
        guard let captured = CaptureClock.hostSeconds(
            presentation: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            sourceClock: session.synchronizationClock),
              let timestamp = freshness.timestamp(captured: captured, now: CaptureClock.now) else {
            buffer.reset()
            localFilter.reset()
            DispatchQueue.main.async {
                guard self.uiGeneration == generation, self.wantsRunning else { return }
                self.hands = []
                self.localSign = nil
                self.frameAgeMS = nil
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
            let count = buffer.frames.count
            rateFrames += 1
            var measuredFPS: Int?
            if now - rateStart >= 1 {
                measuredFPS = Int(Double(rateFrames) / (now - rateStart))
                rateStart = now
                rateFrames = 0
            }
            DispatchQueue.main.async {
                guard self.uiGeneration == generation, self.wantsRunning else { return }
                let age = CaptureClock.now - captured
                let fresh = age >= 0 && age <= 0.4
                self.hands = fresh ? detected : []
                self.localSign = fresh ? local : nil
                self.frameAgeMS = fresh ? Int(age*1000) : nil
                self.lastLocalFrameAt = captured
                if fresh { self.onFrame?(frame) } else { self.onReset?() }
                self.latencyMS = elapsed
                self.bufferedFrames = count
                self.frameSize = CGSize(width: width, height: height)
                if let measuredFPS { self.fps = measuredFPS }
                self.status = !fresh ? "Waiting for fresh camera frames" :
                    detected.isEmpty ? "Looking for hands" : "Tracking \(detected.count) \(detected.count == 1 ? "hand" : "hands")"
            }
        } catch { report(error) }
    }

    private func report(_ error: Error) {
        localFilter.reset()
        let generation = captureGeneration
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
        DispatchQueue.main.async {
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
