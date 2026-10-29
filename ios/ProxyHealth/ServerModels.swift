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

/// Retention, decided per group. The groups, their windows and the wording all come from the
/// server catalog, so adding one is a deploy rather than a rebuild.
struct ServerSettings: Codable, Sendable {
    var retention: [String: Int]
    var groups: [RetentionGroup]
    var defaults: [String: Int]?
}

struct RetentionGroup: Codable, Sendable, Identifiable {
    var id: String
    var name: String
    var summary: String
    /// `days` or `years`: raw signals are measured in days, everything else in years.
    var unit: String
    var options: [Int]
    var `default`: Int
    var note: String

    func label(_ value: Int) -> String { unit == "days" ? "\(value) วัน" : "\(value) ปี" }
}

struct ReadinessDoc: Codable, Sendable {
    struct Factor: Codable, Sendable, Identifiable {
        var key: String
        var score: Int
        var value: Double
        var baseline: Double?
        var deviation: String?
        /// The gap from the baseline as a percentage, shown in brackets after the value.
        var changePercent: Double?
        /// Context that is not the comparison — sleep uses it for time in bed.
        var note: String?
        /// Rendered right after the value in a lighter colour, as in "5:04/7:09".
        var secondary: String?
        var direction: String

        var id: String { key }
        /// Short labels, so the four rows line up and the ⓘ sheet carries the Thai meaning.
        var name: String {
            switch key {
            case "hrv": "HRV"
            case "restingHeartRate": "RHR"
            case "sleep": "Sleep"
            case "load": "Load"
            default: key
            }
        }
    }

    var score: Int?
    /// Frozen for the day once the measured factors are in, so the number cannot drift.
    var locked: Bool?
    var computedAt: Date?
    /// When the night ended — the morning this score is about.
    var wakeTime: Date?
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
        locked: false,
        computedAt: nil,
        wakeTime: nil,
        band: "ready",
        bandLabel: "พร้อม",
        advice: "กำลังโหลด",
        reason: "กำลังคำนวณความพร้อมจากข้อมูลล่าสุด",
        headline: "กำลังคำนวณความพร้อมจากข้อมูลล่าสุด",
        factors: [
            .init(key: "hrv", score: 60, value: 60, baseline: 60, deviation: "—", direction: "good"),
            .init(key: "restingHeartRate", score: 60, value: 60, baseline: 60, deviation: "—", direction: "good"),
            .init(key: "sleep", score: 60, value: 420, baseline: 480, deviation: "—", direction: "good"),
            .init(key: "load", score: 60, value: 30, baseline: 30, deviation: "—", direction: "good"),
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

struct BatteryDoc: Codable, Sendable {
    struct Step: Codable, Sendable, Identifiable {
        var hour: Int
        var level: Double
        var change: Double

        var id: Int { hour }
    }

    var level: Int
    /// Where the level stood when last night began, and where the night brought it to.
    var bedLevel: Int
    var wakeLevel: Int
    var chargedOvernight: Int
    var napCharge: Int
    /// Signed: negative is the usual case; a nap or a very quiet day can make it positive.
    var sinceWake: Int
    var drainedToday: Int
    var steps: [Step]
    var missing: [String]
    /// A missing night or a day without hourly data had to be stood in for.
    var estimated: Bool
    /// The coaching sentence, comparison included when there is enough history for one.
    var message: String?
    var advice: String?
    var basis: String?

    /// Placeholder for the loading state, shown redacted and colourless.
    static let placeholder = BatteryDoc(
        level: 62, bedLevel: 40, wakeLevel: 78, chargedOvernight: 38, napCharge: 0, sinceWake: -16,
        drainedToday: 16, steps: [], missing: [], estimated: false,
        message: "กำลังคำนวณพลังงานที่เหลือ", advice: nil, basis: nil
    )
}

/// Keeps the day's frozen readiness on the device. The server computes it once at wake and locks
/// it, so every later open would fetch a document that cannot have changed.
enum ReadinessCache {
    private static let key = "readiness.locked"
    private static let dayKey = "readiness.lockedDay"

    static func today() -> ReadinessDoc? {
        guard UserDefaults.standard.string(forKey: dayKey) == dayStamp(),
              let data = UserDefaults.standard.data(forKey: key)
        else { return nil }
        return try? decoder.decode(ReadinessDoc.self, from: data)
    }

    static func save(_ readiness: ReadinessDoc) {
        guard let data = try? encoder.encode(readiness) else { return }
        UserDefaults.standard.set(data, forKey: key)
        UserDefaults.standard.set(dayStamp(), forKey: dayKey)
    }

    /// Local day, since that is the day the server anchored the score to.
    private static func dayStamp() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}


/// Training zones, worked out server-side from the heart rate the watch has actually recorded.
struct ZonesDoc: Codable, Sendable {
    struct Zone: Codable, Sendable, Identifiable {
        var zone: Int
        var name: String
        var from: Int
        var to: Int

        var id: Int { zone }
    }

    var max: Int?
    /// `measured` or `estimated` — whether the maximum came from a workout or an age formula.
    var source: String?
    var measuredAt: String?
    var restingHeartRate: Int?
    var method: String?
    var zones: [Zone]
    var note: String?

    /// Shown redacted while the first load is in flight.
    static let placeholder = ZonesDoc(
        max: 190, source: nil, measuredAt: nil, restingHeartRate: 60, method: nil,
        zones: (1...5).map { Zone(zone: $0, name: " ", from: 100 + $0 * 10, to: 110 + $0 * 10) },
        note: nil
    )
}
