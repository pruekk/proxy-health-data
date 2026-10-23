import Foundation

struct APIError: LocalizedError {
    let status: Int
    let body: String
    var errorDescription: String? { "Server returned \(status): \(body.prefix(300))" }
}

struct APIClient: Sendable {
    let baseURL: URL
    let token: String

    init?(settings: SyncSettings) {
        guard settings.isConfigured, let url = URL(string: settings.serverURL) else { return nil }
        baseURL = url
        token = settings.token
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    func me() async throws -> Profile {
        try await send("v1/me", method: "GET", body: Optional<SyncRequest>.none)
    }

    @discardableResult
    func sync(_ request: SyncRequest) async throws -> SyncResponse {
        try await send("v1/sync", method: "POST", body: request)
    }

    private func send<Body: Encodable, Response: Decodable>(_ path: String, method: String, body: Body?) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Self.encoder.encode(body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
