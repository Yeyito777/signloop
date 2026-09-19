import Foundation

@main
struct BackendClientTests {
    static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        let url = URL(string: environment["SIGNLOOP_TEST_URL"]!)!
        let client = BackendClient(baseURL: url, token: environment["SIGNLOOP_TEST_TOKEN"]!)
        precondition(BackendClient.validURL("http://192.168.1.3:8787") != nil)
        precondition(BackendClient.validURL("http://example.com") == nil)
        precondition(BackendClient.validURL("https://user:password@example.com") == nil)
        precondition(BackendClient.validURL("http://10.999.1.2") == nil)
        let status: BackendClient.Status = try await client.request(
            "v1/status", body: BackendClient.Empty(), method: "GET")
        precondition(status.status == "ok" && status.vocabulary.contains("HELLO"))
        let classifier = BackendClassifier(client: client)
        let empty = try await classifier.classify(frames: [])
        precondition(empty.unknown && empty.reason == "no_hands")
        let joints = (0..<21).map {
            Joint(x: 0.5 + Float($0) * 0.005, y: 0.5 + Float($0) * 0.01, z: 0)
        }
        let frames = (0..<12).map {
            LandmarkFrame(timestampMS: $0 * 100, hands: [
                TrackedHand(handedness: "Left", handednessScore: 0.9, joints: joints)
            ])
        }
        let match = try await classifier.classify(frames: frames)
        precondition(!match.unknown && match.candidates.first?.label == "HELLO")
        let caption: BackendClient.Caption = try await client.request(
            "v1/caption", body: BackendClient.Labels(raw_signs: ["HELLO", "THANK_YOU"]))
        precondition(caption.text == "Hello, thank you." && caption.polished)
        precondition(caption.raw_signs == ["HELLO", "THANK_YOU"])
        let badClient = BackendClient(baseURL: url, token: "invalid")
        do {
            let _: BackendClient.Status = try await badClient.request(
                "v1/status", body: BackendClient.Empty(), method: "GET")
            preconditionFailure("Invalid auth must fail")
        } catch is BackendError { }
        print("PASS: native Swift HTTP encoding/decoding, URL policy, unknown, caption and auth (mocked models).")
    }
}
