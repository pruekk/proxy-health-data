import Foundation
import Observation

/// Loads everything the three tabs show. One place so a pull-to-refresh updates all of them and
/// the views stay free of networking.
@MainActor
@Observable
final class Dashboard {
    var metrics: [String: MetricSummary] = [:]
    var days: [DailyDoc] = []
    var workouts: [WorkoutDoc] = []
    var syncs: [SyncLogDoc] = []
    var connectors: [ConnectorDoc] = []
    var retentionYears = 1
    var isLoading = false
    var error: String?
    var loadedAt: Date?

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601DateFormatter.withFractionalSeconds.date(from: text) { return date }
            if let date = ISO8601DateFormatter.plain.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(text)"))
        }
        return decoder
    }()

    func load(settings: SyncSettings, force: Bool = false) async {
        guard let client = APIClient(settings: settings) else { return }
        // A tab switch should not re-fetch what was loaded seconds ago.
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < 60 { return }
        isLoading = true
        defer { isLoading = false }

        let today = Self.dayKey(Date())
        let from = Self.dayKey(Calendar.current.date(byAdding: .day, value: -89, to: Date())!)
        do {
            async let metrics: [MetricSummary] = fetch(client, "v1/metrics")
            async let days: [DailyDoc] = fetch(client, "v1/daily?from=\(from)&to=\(today)")
            async let workouts: [WorkoutDoc] = fetch(client, "v1/workouts?limit=10")
            async let syncs: [SyncLogDoc] = fetch(client, "v1/syncs?limit=30")
            async let connectors: [ConnectorDoc] = fetch(client, "v1/connectors")
            async let serverSettings: ServerSettings = fetch(client, "v1/settings")

            self.metrics = Dictionary(uniqueKeysWithValues: try await metrics.map { ($0.type, $0) })
            self.days = try await days
            self.workouts = try await workouts
            self.syncs = try await syncs
            self.connectors = try await connectors
            self.retentionYears = try await serverSettings.retentionYears
            self.error = nil
            self.loadedAt = Date()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func fetch<T: Decodable>(_ client: APIClient, _ path: String) async throws -> T {
        let data: Data = try await client.getRaw(path)
        return try Self.decoder.decode(T.self, from: data)
    }

    // MARK: Derived

    var today: DailyDoc? { days.last }

    func metric(_ type: String) -> MetricSummary? { metrics[type] }

    /// Change in a metric over the loaded window, using the daily aggregates so a value that is
    /// only recorded now and then still produces a trend.
    func change(_ type: String) -> (delta: Double, days: Int)? {
        let points = days.compactMap { day -> Double? in day.value(type) }
        guard let first = points.first, let last = points.last, points.count > 1 else { return nil }
        return (last - first, days.count)
    }

    func average(_ type: String, lastDays: Int) -> Double? {
        let points = days.suffix(lastDays).compactMap { $0.value(type) }
        guard !points.isEmpty else { return nil }
        return points.reduce(0, +) / Double(points.count)
    }

    private static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

extension ISO8601DateFormatter {
    static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    static let plain = ISO8601DateFormatter()
}
