import Foundation
import Security

struct BackendClient {
    let baseURL: URL
    let token: String // Local backend access token, NEVER a provider API key.

    static func validURL(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { return nil }
        if url.scheme == "https" { return url }
        // Cleartext development traffic is limited to local hostnames/addresses.
        let pieces = host.split(separator: ".").compactMap { Int($0) }
        let privateIP = pieces.count == 4 && pieces.allSatisfy { 0...255 ~= $0 } &&
            (pieces[0] == 10 || (pieces[0] == 192 && pieces[1] == 168) ||
             (pieces[0] == 172 && 16...31 ~= pieces[1]) || pieces[0] == 127)
        guard url.scheme == "http",
              host == "localhost" || host.hasSuffix(".local") || privateIP else { return nil }
        return url
    }

    func request<Response: Decodable, Body: Encodable>(
        _ path: String, body: Body, method: String = "POST"
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 50
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if method == "POST" { request.httpBody = try JSONEncoder().encode(body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BackendError("Invalid server response.") }
        guard http.statusCode == 200 else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.message
            throw BackendError(message ?? "Backend returned HTTP \(http.statusCode).")
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    struct ErrorResponse: Decodable { let message: String }
    struct Empty: Codable {}
    struct Frames: Encodable { let frames: [LandmarkFrame] }
    struct Labels: Encodable {
        let raw_signs: [String]
    }
    struct Reference: Encodable {
        let label: String
        let frames: [LandmarkFrame]
        let human_confirmed = true
    }
    struct ReferenceStatus: Decodable { let labels: [String] }
    struct DeleteStatus: Decodable { let deleted: Bool }
    struct Caption: Decodable {
        let text: String
        let raw_signs: [String]
        let polished: Bool
        let model: String?
    }
}

struct BackendClassifier: SignClassifier {
    let client: BackendClient
    func classify(frames: [LandmarkFrame]) async throws -> Classification {
        try await client.request("v1/classify", body: BackendClient.Frames(frames: frames))
    }
}

struct BackendError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum BackendTokenStore {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.yeyito.signloop.backend",
        kSecAttrAccount as String: "local-access-token",
    ]

    static func read() -> String {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func save(_ token: String) {
        SecItemDelete(query as CFDictionary)
        guard !token.isEmpty else { return }
        var value = query
        value[kSecValueData as String] = Data(token.utf8)
        value[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(value as CFDictionary, nil)
    }
}
