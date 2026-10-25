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
    /// Exact, from an aggregation query. `sampleCount` is a running total that never saw the
    /// documents written before it existed and does not decrease when TTL deletes.
    var count: Int?
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

struct ReadinessDoc: Codable, Sendable {
    struct Factor: Codable, Sendable, Identifiable {
        var key: String
        var score: Int
        var value: Double
        var baseline: Double?
        var deviation: String?
        /// Context that is not the comparison — sleep uses it for time in bed.
        var note: String?
        var direction: String

        var id: String { key }
        var name: String {
            switch key {
            case "hrv": "HRV"
            case "restingHeartRate": "ชีพจรพัก"
            case "sleep": "หลับจริง"
            case "load": "โหลด 7 วัน"
            default: key
            }
        }
    }

    var score: Int?
    var band: String?
    var bandLabel: String?
    var advice: String?
    /// Why the score is what it is, without the advice glued on.
    var reason: String?
    var headline: String?
    var factors: [Factor]
    var missing: [String]
    var basis: String?

    /// Shape for the loading state, shown redacted.
    static let placeholder = ReadinessDoc(
        score: 72,
        band: "ready",
        bandLabel: "พร้อม",
        advice: "กำลังโหลด",
        reason: "กำลังคำนวณความพร้อมจากข้อมูลล่าสุด",
        headline: "กำลังคำนวณความพร้อมจากข้อมูลล่าสุด",
        factors: [
            .init(key: "hrv", score: 60, value: 60, baseline: 60, deviation: "—", note: nil, direction: "good"),
            .init(key: "restingHeartRate", score: 60, value: 60, baseline: 60, deviation: "—", note: nil, direction: "good"),
            .init(key: "sleep", score: 60, value: 420, baseline: 480, deviation: "—", note: nil, direction: "good"),
            .init(key: "load", score: 60, value: 30, baseline: 30, deviation: "—", note: nil, direction: "good"),
        ],
        missing: [],
        basis: " "
    )

    var missingNames: String {
        missing.map {
            switch $0 {
            case "hrv": "HRV"
            case "restingHeartRate": "ชีพจรพัก"
            case "sleep": "หลับจริง"
            case "load": "โหลดการซ้อม"
            default: $0
            }
        }.joined(separator: ", ")
    }
}

struct RetentionResult: Codable, Sendable {
    var scope: String
    var scanned: Int
    var stamped: Int
    var done: Bool
    var after: String?
}

/// Progress of a retention re-stamp: counted, not guessed.
struct RetentionProgress: Sendable {
    var done: Int
    var total: Int
    var stamped: Int
    var scope: String?

    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    var label: String {
        if done >= total { return "ปรับข้อมูลเดิมเสร็จแล้ว · \(stamped) รายการ" }
        return "กำลังปรับข้อมูลเดิม \(done)/\(total) ประเภท · \(stamped) รายการ"
    }
}
