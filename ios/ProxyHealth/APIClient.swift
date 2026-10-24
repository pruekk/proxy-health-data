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

    /// Returns nil when the server says the catalog is unchanged (304), so an unchanged catalog
    /// costs one small request and no decoding.
    func catalog(knownVersion: String?) async throws -> RemoteCatalog? {
        let path = knownVersion.map { "v1/catalog?version=\($0)" } ?? "v1/catalog"
        return try await sendOptional(path, method: "GET")
    }

    @discardableResult
    func sync(_ request: SyncRequest) async throws -> SyncResponse {
        try await send("v1/sync", method: "POST", body: request)
    }

    /// Like `send`, but treats 304 Not Modified as "nothing to do" instead of an error.
    private func sendOptional<Response: Decodable>(_ path: String, method: String) async throws -> Response? {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 304 { return nil }
        guard (200..<300).contains(status) else {
            throw APIError(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode(Response.self, from: data)
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
