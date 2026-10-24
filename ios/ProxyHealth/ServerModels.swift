import Foundation

// Shapes returned by the read endpoints. The app shows what actually reached the server, so the
// numbers on screen are the same ones the MCP tools report.

struct MetricSummary: Codable, Sendable, Identifiable {
    struct Latest: Codable, Sendable {
        var value: Double?
        var unit: String?
        var valueLabel: String?
        var startDate: Date?
        var sourceName: String?
    }

    var type: String
    var unit: String?
    var kind: String?
    var latest: Latest?
    var firstAt: Date?
    var sampleCount: Int?
    var sources: [String: Int]?

    var id: String { type }
    var value: Double? { latest?.value }
    var measuredAt: Date? { latest?.startDate }
}

struct DailyDoc: Codable, Sendable, Identifiable {
    struct Stat: Codable, Sendable {
        var sum: Double?
        var avg: Double?
        var min: Double?
        var max: Double?
        /// Cumulative metrics carry a sum, discrete ones an average.
        var value: Double? { sum ?? avg }
    }

    struct Activity: Codable, Sendable {
        var activeEnergyKcal: Double?
        var activeEnergyGoalKcal: Double?
        var exerciseMinutes: Double?
        var exerciseMinutesGoal: Double?
        var standHours: Double?
        var standHoursGoal: Double?
    }

    var date: String
    var metrics: [String: Stat]?
    var activity: Activity?

    var id: String { date }
    func value(_ type: String) -> Double? { metrics?[type]?.value }
}

struct WorkoutDoc: Codable, Sendable, Identifiable {
    var id: String
    var activityTypeName: String
    var startDate: Date
    var durationSec: Double
    var distanceM: Double?
    var avgHeartRate: Double?
    var maxHeartRate: Double?
    var weatherTempC: Double?
    var weatherHumidityPercent: Double?
}

struct SyncLogDoc: Codable, Sendable, Identifiable {
    var startedAt: Date
    var durationMs: Double?
    var trigger: String?
    var samples: Int?
    var workouts: Int?
    var days: Int?
    var catalogVersion: String?
    var errors: [String]?

    var id: Date { startedAt }
    var failed: Bool { !(errors ?? []).isEmpty }
}

struct ConnectorDoc: Codable, Sendable, Identifiable {
    var clientId: String
    var clientName: String
    var since: String?
    var expiresAt: String?

    var id: String { clientId }
}

struct ServerSettings: Codable, Sendable {
    var retentionYears: Int
    var defaultRetentionYears: Int?
}
