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
    /// Windows per retention group, and the group metadata that describes them.
    var retention: [String: Int] = [:]
    var retentionGroups: [RetentionGroup] = []
    var readiness: ReadinessDoc?
    var battery: BatteryDoc?
    /// Reports this device wrote, shown immediately so the history does not wait for the server
    /// to acknowledge a sync that already finished.
    var localSyncs: [SyncReport] = SyncState.recentSyncs
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
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < AppConfig.dashboardCacheSeconds { return }
        isLoading = true
        failures = []
        defer { isLoading = false }

        let today = Self.dayKey(Date())
        let from = Self.dayKey(Calendar.current.date(byAdding: .day, value: -(AppConfig.dashboardDays - 1), to: Date())!)
        // Each read stands on its own: one endpoint failing should cost its own section, not
        // blank every tab.
        async let metrics: [MetricSummary]? = optional(client, "v1/metrics?counts=true")
        async let days: [DailyDoc]? = optional(client, "v1/daily?from=\(from)&to=\(today)")
        async let workouts: [WorkoutDoc]? = optional(client, "v1/workouts?limit=\(AppConfig.workoutsLimit)")
        async let syncs: [SyncLogDoc]? = optional(client, "v1/syncs?limit=\(AppConfig.syncsLimit)")
        async let connectors: [ConnectorDoc]? = optional(client, "v1/connectors")
        async let serverSettings: ServerSettings? = optional(client, "v1/settings")
        // Once the server has frozen the day's score there is nothing new to fetch until
        // tomorrow, so a reopened app reads it from here instead of making the round trip.
        let cachedReadiness = ReadinessCache.today()
        async let readiness: ReadinessDoc? = cachedReadiness == nil ? optional(client, "v1/readiness") : nil
        async let battery: BatteryDoc? = optional(client, "v1/battery")

        if let metrics = await metrics {
            self.metrics = Dictionary(uniqueKeysWithValues: metrics.map { ($0.type, $0) })
        }
        if let days = await days { self.days = days }
        if let workouts = await workouts { self.workouts = workouts }
        if let syncs = await syncs { self.syncs = syncs }
        if let connectors = await connectors { self.connectors = connectors }
        if let serverSettings = await serverSettings {
            self.retention = serverSettings.retention
            self.retentionGroups = serverSettings.groups
        }
        // Keep the last good value when a single read fails, like every other field here —
        // overwriting with nil made the readiness card vanish on a hiccup.
        if let cachedReadiness {
            self.readiness = cachedReadiness
        } else if let readiness = await readiness {
            self.readiness = readiness
            if readiness.locked == true { ReadinessCache.save(readiness) }
        }
        if let battery = await battery { self.battery = battery }
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

    /// Picks up reports written by a sync that just finished.
    func refreshLocalSyncs() {
        localSyncs = SyncState.recentSyncs
    }

    /// The device's own reports merged with the server's, newest first and de-duplicated, so
    /// both tabs tell the same story the moment a sync ends rather than a round trip later.
    var syncHistory: [SyncLogDoc] {
        let local = localSyncs.filter { !$0.skipped }.map {
            SyncLogDoc(
                startedAt: $0.startedAt,
                durationMs: $0.durationMs,
                trigger: $0.trigger.rawValue,
                samples: $0.samples,
                workouts: $0.workouts,
                days: $0.days,
                catalogVersion: nil,
                errors: $0.errors.isEmpty ? nil : $0.errors
            )
        }
        return SyncMerge.dedupedByTimestamp(local + syncs) { $0.startedAt }
    }

    var lastSync: SyncLogDoc? { syncHistory.first }

    // MARK: Derived

    var today: DailyDoc? { days.last }

    func metric(_ type: String) -> MetricSummary? { metrics[type] }

    /// Everything stored, when the counts have been loaded.
    var totalDocuments: Int? {
        let counted = metrics.values.compactMap(\.count)
        return counted.isEmpty ? nil : counted.reduce(0, +)
    }

    /// Documents stored for a group, summed from the per-metric counts already loaded.
    func documentCount(in group: String) -> Int {
        let keys = AppConfig.metricKeys(in: group)
        return metrics.values.filter { keys.contains($0.type) }.reduce(0) { $0 + ($1.count ?? 0) }
    }

    /// How long this metric is kept, in the group's own words — "7 วัน", "5 ปี".
    func windowLabel(for type: String) -> String {
        guard let group = retentionGroups.first(where: { AppConfig.metricKeys(in: $0.id).contains(type) })
        else { return "—" }
        return "เก็บ " + group.label(retention[group.id] ?? group.default)
    }

    /// The metrics in a group that actually hold something, largest first.
    func storedMetrics(in group: String) -> [MetricSummary] {
        let keys = AppConfig.metricKeys(in: group)
        return metrics.values
            .filter { keys.contains($0.type) && ($0.count ?? 0) > 0 }
            .sorted { ($0.count ?? 0) > ($1.count ?? 0) }
    }

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
