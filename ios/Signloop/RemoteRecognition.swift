import Combine
import Foundation

@MainActor
final class RemoteRecognition: ObservableObject {
    @Published var address = UserDefaults.standard.string(forKey: "backendAddress") ?? "" {
        didSet { UserDefaults.standard.set(address, forKey: "backendAddress"); consent = false }
    }
    @Published var token = BackendTokenStore.read() {
        didSet { BackendTokenStore.save(token); consent = false }
    }
    @Published var consent = false {
        didSet {
            if !consent {
                generation += 1
                activeTask?.cancel()
                activeTask = nil
                busy = false
            }
        }
    }
    @Published private(set) var busy = false
    @Published private(set) var rawSigns: [String] = []
    @Published private(set) var text = ""
    @Published private(set) var status = "Backend disconnected"
    @Published private(set) var references: [String] = []
    @Published private(set) var lastScores = ""
    @Published private(set) var captionModel = ""
    @Published private(set) var polished = false
    let vocabulary = ["HELLO", "THANK_YOU", "YES", "NO", "PLEASE"]
    private var lastEmitted: String?
    private var generation = 0
    private var activeTask: Task<Void, Never>?

    var configured: Bool { BackendClient.validURL(address) != nil && token.count >= 24 }

    private func client() throws -> BackendClient {
        guard let url = BackendClient.validURL(address), token.count >= 24 else {
            throw BackendError("Set a local backend URL and its separate access token.")
        }
        return BackendClient(baseURL: url, token: token)
    }

    func configure(from url: URL) {
        guard url.scheme == "signloop", url.host == "connect",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let address = items.first(where: { $0.name == "url" })?.value,
              let token = items.first(where: { $0.name == "token" })?.value,
              BackendClient.validURL(address) != nil, token.count >= 24 else { return }
        self.address = address
        self.token = token
        self.status = "Backend configured · review sharing settings"
        // A connection link never grants permission to send landmarks.
    }

    func handsLeftFrame() { lastEmitted = nil }

    func clear() {
        generation += 1
        activeTask?.cancel()
        activeTask = nil
        busy = false
        rawSigns = []
        text = ""
        lastScores = ""
        lastEmitted = nil
        status = "Transcript cleared"
    }

    func checkConnection() async {
        do {
            let response: BackendClient.ReferenceStatus = try await client().request(
                "v1/references", body: BackendClient.Empty(), method: "GET")
            references = response.labels
            status = "Connected · \(references.count) reference signs"
        } catch { status = error.localizedDescription }
    }

    func deleteReferences() async {
        do {
            let _: BackendClient.DeleteStatus = try await client().request(
                "v1/references", body: BackendClient.Empty(), method: "DELETE")
            references = []
            status = "Server references deleted"
        } catch { status = error.localizedDescription }
    }

    func saveReference(label: String, tracker: CameraTracker) {
        guard consent, !busy else { return }
        busy = true
        let currentGeneration = generation
        activeTask = Task {
            defer { if generation == currentGeneration { busy = false } }
            do {
                let frames = await tracker.recentFrames()
                try Task.checkCancellation()
                let response: BackendClient.ReferenceStatus = try await client().request(
                    "v1/references", body: BackendClient.Reference(label: label, frames: frames))
                guard generation == currentGeneration else { return }
                references = response.labels
                status = "Saved \(label) example · not independently validated"
            } catch {
                if generation == currentGeneration { status = error.localizedDescription }
            }
        }
    }

    /// Explicit button press segments the preceding two seconds. No hidden upload.
    func analyze(tracker: CameraTracker) {
        guard consent, !busy else { return }
        busy = true
        status = "Jev is comparing this gesture…"
        let currentGeneration = generation
        activeTask = Task {
            defer { if generation == currentGeneration { busy = false } }
            do {
                let client = try client()
                let frames = await tracker.recentFrames()
                try Task.checkCancellation()
                let result = try await BackendClassifier(client: client).classify(frames: frames)
                guard generation == currentGeneration else { return }
                lastScores = result.candidates.prefix(3).map {
                    "\($0.label) \(String(format: "%.2f", $0.score))"
                }.joined(separator: " · ")
                guard !result.unknown, let candidate = result.candidates.first else {
                    status = result.reason == "no_references" ? "Add reference examples in Backend settings" :
                        "Unknown — no sign added (\(result.reason ?? "uncertain"))"
                    return
                }
                guard vocabulary.contains(candidate.label), candidate.score >= 0.8 else {
                    status = "Uncertain — no sign added"
                    return
                }
                guard candidate.label != lastEmitted else {
                    status = "Duplicate held sign skipped · lower hands before repeating"
                    return
                }
                guard rawSigns.count < 30 else {
                    status = "Phrase limit reached — clear to start another"
                    return
                }
                rawSigns.append(candidate.label)
                lastEmitted = candidate.label
                // Immediately show conservative raw rendering if the LLM fails.
                text = rawSigns.map { $0.replacingOccurrences(of: "_", with: " ").lowercased() }.joined(separator: ". ")
                polished = false
                status = "Cerebras is formatting the recognized labels…"
                let caption: BackendClient.Caption = try await client.request(
                    "v1/caption", body: BackendClient.Labels(raw_signs: rawSigns))
                guard generation == currentGeneration else { return }
                guard caption.raw_signs == rawSigns else { throw BackendError("Caption label mismatch.") }
                text = caption.text
                polished = caption.polished
                captionModel = caption.model ?? ""
                status = caption.polished ? "Experimental caption · verify the raw signs" : "Conservative caption · meaning guard applied"
            } catch {
                if generation == currentGeneration { status = error.localizedDescription }
            }
        }
    }
}
