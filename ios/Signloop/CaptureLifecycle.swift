import Foundation

/// Shared by the UI and capture queue. A pause invalidates queued starts,
/// permission replies, and inference publications before stopRunning completes.
final class CaptureLifecycle {
    private let lock = NSLock()
    private var generation = 0
    private var requested = false

    func begin() -> Int {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        requested = true
        return generation
    }

    func end() {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        requested = false
    }

    var token: Int? {
        lock.lock(); defer { lock.unlock() }
        return requested ? generation : nil
    }

    func accepts(_ token: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return requested && generation == token
    }
}
