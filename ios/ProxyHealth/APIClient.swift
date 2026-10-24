import Foundation

struct APIError: LocalizedError {
    let status: Int
    let body: String
    var errorDescription: String? { "Server returned \(status): \(body.prefix(300))" }
}

/// For endpoints that answer `{ "ok": true }` and nothing worth decoding.
struct OK: Codable, Sendable { var ok: Bool? }

struct APIClient: Sendable {
    let baseURL: URL
    let token: String

    init?(settings: SyncSettings) {
        guard settings.isConfigured, let url = URL(string: settings.serverURL) else { return nil }
        baseURL = url
        token = settings.token
    }

    private func url(for pathAndQuery: String) -> URL {
        APIPath.url(base: baseURL, pathAndQuery: pathAndQuery)
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

    func recordSync(_ entry: SyncLogPayload) async throws {
        let _: OK = try await send("v1/syncs", method: "POST", body: entry)
    }

    /// Reads for the UI. Raw bytes, because the dashboard decodes with its own date strategy —
    /// the server sends ISO strings with and without fractional seconds.
    func getRaw(_ path: String) async throws -> Data {
        var request = URLRequest(url: url(for: path))
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return data
    }

    func put<Body: Encodable>(_ path: String, body: Body) async throws {
        let _: OK = try await send(path, method: "PUT", body: body)
    }

    func postDecoding<Response: Decodable>(_ path: String) async throws -> Response {
        try await send(path, method: "POST", body: Optional<SyncRequest>.none)
    }

    func post(_ path: String) async throws {
        let _: OK = try await send(path, method: "POST", body: Optional<SyncRequest>.none)
    }

    func delete(_ path: String) async throws {
        let _: OK = try await send(path, method: "DELETE", body: Optional<SyncRequest>.none)
    }

    /// Like `send`, but treats 304 Not Modified as "nothing to do" instead of an error.
    private func sendOptional<Response: Decodable>(_ path: String, method: String) async throws -> Response? {
        var request = URLRequest(url: url(for: path))
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
        var request = URLRequest(url: url(for: path))
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
