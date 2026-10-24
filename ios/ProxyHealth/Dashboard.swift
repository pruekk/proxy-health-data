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
            guard let date = ISODate.parse(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(text)"))
            }
            return date
        }
        return decoder
    }()

    func load(settings: SyncSettings, force: Bool = false) async {
        guard let client = APIClient(settings: settings) else { return }
        // A tab switch should not re-fetch what was loaded seconds ago.
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < 60 { return }
        isLoading = true
        failures = []
        defer { isLoading = false }

        let today = Self.dayKey(Date())
        let from = Self.dayKey(Calendar.current.date(byAdding: .day, value: -89, to: Date())!)
        // Each read stands on its own: one endpoint failing should cost its own section, not
        // blank every tab.
        async let metrics: [MetricSummary]? = optional(client, "v1/metrics")
        async let days: [DailyDoc]? = optional(client, "v1/daily?from=\(from)&to=\(today)")
        async let workouts: [WorkoutDoc]? = optional(client, "v1/workouts?limit=10")
        async let syncs: [SyncLogDoc]? = optional(client, "v1/syncs?limit=30")
        async let connectors: [ConnectorDoc]? = optional(client, "v1/connectors")
        async let serverSettings: ServerSettings? = optional(client, "v1/settings")

        if let metrics = await metrics {
            self.metrics = Dictionary(uniqueKeysWithValues: metrics.map { ($0.type, $0) })
        }
        if let days = await days { self.days = days }
        if let workouts = await workouts { self.workouts = workouts }
        if let syncs = await syncs { self.syncs = syncs }
        if let connectors = await connectors { self.connectors = connectors }
        if let serverSettings = await serverSettings { self.retentionYears = serverSettings.retentionYears }
        self.error = failures.isEmpty ? nil : failures.joined(separator: " · ")
        self.loadedAt = Date()
    }

    private var failures: [String] = []

    private func optional<T: Decodable>(_ client: APIClient, _ path: String) async -> T? {
        do {
            return try Self.decoder.decode(T.self, from: await client.getRaw(path))
        } catch {
            failures.append("\(path.split(separator: "?")[0]): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Derived

    var today: DailyDoc? { days.last }

    func metric(_ type: String) -> MetricSummary? { metrics[type] }

    /// Change in a metric over the loaded window, using the daily aggregates so a value that is
    /// only recorded now and then still produces a trend.
    /// Change for a metric, reported over the number of days it actually spans rather than the
    /// number of readings — eight weigh-ins can cover three months.
    func change(_ type: String) -> (delta: Double, days: Int)? {
        guard let result = Trends.change(days.map { $0.value(type) }) else { return nil }
        let dated = days.filter { $0.value(type) != nil }
        let span = dated.first.flatMap { first in
            dated.last.flatMap { Trends.spanDays(from: first.date, to: $0.date) }
        }
        return (result.delta, span ?? result.points)
    }

    func average(_ type: String, lastDays: Int) -> Double? {
        Trends.average(days.suffix(lastDays).map { $0.value(type) }, window: lastDays)
    }

    private static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
