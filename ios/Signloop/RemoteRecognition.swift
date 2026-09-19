import Combine
import Foundation

/// Latest-window inference: one request in flight, no queue, no saved samples.
@MainActor
final class RemoteRecognition: ObservableObject {
    @Published private(set) var currentSign = "Ready"
    @Published private(set) var status = "Starting live recognition"
    @Published private(set) var live = false
    @Published private(set) var latencyMS = 0
    private var address = UserDefaults.standard.string(forKey: "backendAddress") ?? ""
    private var token = BackendTokenStore.read()
    private var activeTask: Task<Void, Never>?
    private var generation = 0
    private var observationEpoch = 0
    private var filter = LiveSignFilter()
    private var lastResultAt = Date.distantPast
    private var hasHands = false
    private let labels = Set(["HELLO", "THANK_YOU", "YES", "NO", "PLEASE", "I_LOVE_YOU"])

    init() {
        // The deploy helper provisions this small file into the app sandbox.
        // It contains only a LAN URL + backend access token, never a provider key.
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("backend-connection.json")
        if let data = try? Data(contentsOf: file),
           let config = try? JSONDecoder().decode(Connection.self, from: data),
           BackendClient.validURL(config.url) != nil, config.token.count >= 24 {
            address = config.url
            token = config.token
            UserDefaults.standard.set(address, forKey: "backendAddress")
            BackendTokenStore.save(token)
            try? FileManager.default.removeItem(at: file)
        }
    }

    private struct Connection: Decodable { let url: String; let token: String }

    func trackingChanged(hasHands: Bool) {
        self.hasHands = hasHands
        if !hasHands {
            observationEpoch += 1
            filter.reset()
            currentSign = "No hands"
            status = "Bring your hands into view"
        }
    }

    func invalidate() {
        observationEpoch += 1
        filter.reset()
        currentSign = "Looking…"
    }

    func expireResult() {
        if live && hasHands && Date().timeIntervalSince(lastResultAt) > 2.5 {
            filter.reset()
            currentSign = "Looking…"
        }
    }

    func start(tracker: CameraTracker) {
        guard activeTask == nil else { return }
        live = true
        let run = generation
        activeTask = Task {
            var failures = 0
            while !Task.isCancelled && generation == run {
                guard let url = BackendClient.validURL(address), token.count >= 24 else {
                    currentSign = "Connecting…"
                    status = "Waiting for the demo backend"
                    try? await Task.sleep(for: .seconds(2))
                    continue
                }
                if !tracker.isRunning || tracker.hands.isEmpty {
                    trackingChanged(hasHands: false)
                    try? await Task.sleep(for: .milliseconds(200))
                    continue
                }
                hasHands = true
                let epoch = observationEpoch
                let camera = tracker.isFront
                let start = Date()
                do {
                    let frames = await tracker.recentFrames()
                    try Task.checkCancellation()
                    let result = try await BackendClassifier(
                        client: BackendClient(baseURL: url, token: token)
                    ).classify(frames: frames)
                    guard generation == run && !Task.isCancelled else { break }
                    guard epoch == observationEpoch, camera == tracker.isFront, !tracker.hands.isEmpty else { continue }
                    let age = Date().timeIntervalSince(start)
                    guard age < 2.5 else {
                        invalidate()
                        status = "Connection slow · waiting for a fresh result"
                        try? await Task.sleep(for: .milliseconds(500))
                        continue
                    }
                    latencyMS = Int(age * 1000)
                    lastResultAt = Date()
                    failures = 0
                    let match = !result.unknown ? result.candidates.first : nil
                    // Backend owns model-specific rejection. DTW similarities
                    // are not Jev scores or calibrated probabilities.
                    let label = match.flatMap { labels.contains($0.label) ? $0.label : nil }
                    let visible = filter.update(label)
                    currentSign = visible?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Unknown"
                    status = visible == nil ? "No clear sign yet" : "Possible sign · live estimate"
                } catch {
                    guard generation == run && !Task.isCancelled else { break }
                    filter.reset()
                    failures += 1
                    currentSign = "Connecting…"
                    status = "Reconnecting to the demo backend"
                }
                // Roughly one request/second; duration counts toward the interval.
                // Back off when offline, and never queue old camera windows.
                let delay = failures > 0 ? min(Double(failures) * 1.5, 6) :
                    max(0.15, 1 - Date().timeIntervalSince(start))
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    func stop() {
        generation += 1
        activeTask?.cancel()
        activeTask = nil
        live = false
        filter.reset()
        currentSign = "Paused"
        status = "Camera and live analysis paused"
    }
}
