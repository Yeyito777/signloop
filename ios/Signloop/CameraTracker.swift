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
    @Published private(set) var fps = 0
    @Published private(set) var bufferedFrames = 0
    @Published private(set) var frameSize = CGSize(width: 720, height: 1280)
    @Published var showJoints = false
    @Published var showNumbers = false
    @Published private(set) var snapshotURL: URL?

    private let queue = DispatchQueue(label: "com.signloop.camera", qos: .userInitiated)
    private var landmarker: HandLandmarker?
    private var configured = false
    private var front = true
    private var lastTimestamp = -1
    private var lastInference = 0.0
    private var rateStart = 0.0
    private var rateFrames = 0
    private var buffer = TemporalBuffer()
    private var observers: [NSObjectProtocol] = []
    private let lifecycle = CaptureLifecycle()
    private let modelPath: String?

    init(modelPath: String? = Bundle.main.path(forResource: "hand_landmarker", ofType: "task")) {
        self.modelPath = modelPath
        super.init()
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionWasInterrupted, object: session, queue: .main
        ) { [weak self] _ in
            self?.hands = []
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
            self.hands = []
            self.errorMessage = error?.localizedDescription ?? "Camera error. Tap Resume to retry."
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func start() {
        hands = []
        requestStart(token: lifecycle.begin())
    }

    private func requestStart(token: Int) {
        guard lifecycle.accepts(token) else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permissionDenied = false
            errorMessage = nil
            queue.async { self.startOnQueue(token: token) }
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
        hands = []
        isRunning = false
        queue.async {
            self.session.stopRunning()
            self.buffer.reset()
            DispatchQueue.main.async {
                guard self.lifecycle.token == nil else { return }
                self.isRunning = false
                self.hands = []
                self.bufferedFrames = 0
                self.fps = 0
                self.latencyMS = 0
                self.status = "Camera paused"
            }
        }
    }

    func flipCamera() {
        queue.async {
            guard self.configured else { return }
            let wasRunning = self.session.isRunning
            self.session.stopRunning()
            do {
                try self.replaceInput(front: !self.front)
                self.buffer.reset()
                if wasRunning { self.session.startRunning() }
                let nowFront = self.front
                DispatchQueue.main.async {
                    self.isFront = nowFront
                    self.hands = []
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
                let tracker = "MediaPipe Hand Landmarker 0.10.21"
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

    func recentFrames() async -> [LandmarkFrame] {
        await withCheckedContinuation { continuation in
            queue.async {
                let cutoff = (self.buffer.frames.last?.timestampMS ?? 0) - 1200
                continuation.resume(returning: self.buffer.frames.filter { $0.timestampMS >= cutoff })
            }
        }
    }

    private func startOnQueue(token: Int) {
        guard lifecycle.accepts(token) else { return }
        do {
            if landmarker == nil {
                guard let model = modelPath else {
                    throw TrackerError.message("Missing hand model. Run ios/scripts/bootstrap.sh and rebuild.")
                }
                let options = HandLandmarkerOptions()
                options.baseOptions.modelAssetPath = model
                options.runningMode = .video
                options.numHands = 2
                options.minHandDetectionConfidence = 0.55
                options.minHandPresenceConfidence = 0.55
                options.minTrackingConfidence = 0.55
                landmarker = try HandLandmarker(options: options)
            }
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
            rateStart = CACurrentMediaTime()
            rateFrames = 0
            guard lifecycle.accepts(token) else { return }
            session.startRunning()
            guard lifecycle.accepts(token) else { session.stopRunning(); return }
            let running = session.isRunning
            DispatchQueue.main.async {
                guard self.lifecycle.accepts(token) else { return }
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
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = front
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard session.isRunning, let landmarker, let token = lifecycle.token else { return }
        let now = CACurrentMediaTime()
        guard now - lastInference >= 1.0 / 24.0 else { return }
        lastInference = now
        let timestamp = max(lastTimestamp + 1, Int(now * 1000))
        lastTimestamp = timestamp
        do {
            // Pixel buffers are physically rotated/mirrored by the output connection.
            let image = try MPImage(sampleBuffer: sampleBuffer, orientation: .up)
            let result = try landmarker.detect(videoFrame: image, timestampInMilliseconds: timestamp)
            let elapsed = Int((CACurrentMediaTime() - now) * 1000)
            let detected = result.landmarks.enumerated().map { index, landmarks in
                let category = result.handedness[safe: index]?.first
                return TrackedHand(handedness: category?.categoryName ?? "Hand",
                                   handednessScore: category?.score ?? 0,
                                   joints: landmarks.map { Joint(x: $0.x, y: $0.y, z: $0.z) })
            }
            buffer.append(LandmarkFrame(timestampMS: timestamp, hands: detected))
            let count = buffer.frames.count
            let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            let width = pixelBuffer.map { CVPixelBufferGetWidth($0) } ?? 720
            let height = pixelBuffer.map { CVPixelBufferGetHeight($0) } ?? 1280
            rateFrames += 1
            var measuredFPS: Int?
            if now - rateStart >= 1 {
                measuredFPS = Int(Double(rateFrames) / (now - rateStart))
                rateStart = now
                rateFrames = 0
            }
            DispatchQueue.main.async {
                guard self.lifecycle.accepts(token) else { return }
                self.hands = detected
                self.latencyMS = elapsed
                self.bufferedFrames = count
                self.frameSize = CGSize(width: width, height: height)
                if let measuredFPS { self.fps = measuredFPS }
                self.status = detected.isEmpty ? "Looking for hands" : "Tracking \(detected.count) \(detected.count == 1 ? "hand" : "hands")"
            }
        } catch { report(error, token: token) }
    }

    private func report(_ error: Error, token: Int? = nil) {
        DispatchQueue.main.async {
            if let token, !self.lifecycle.accepts(token) { return }
            self.hands = []
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
