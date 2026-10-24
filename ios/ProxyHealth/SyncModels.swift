import Foundation
import HealthKit

// Request/response bodies for POST /v1/sync. Field names mirror server/src/schemas.ts.

enum MetaValue: Codable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else { self = .string(try container.decode(String.self)) }
    }

    /// Flattens HealthKit metadata (NSNumber, String, Date, HKQuantity) into JSON-safe values.
    static func from(_ metadata: [String: Any]?) -> [String: MetaValue]? {
        guard let metadata, !metadata.isEmpty else { return nil }
        var out: [String: MetaValue] = [:]
        for (key, value) in metadata {
            switch value {
            case let number as NSNumber:
                out[key] = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
            case let string as String:
                out[key] = .string(string)
            case let date as Date:
                out[key] = .string(ISO8601DateFormatter().string(from: date))
            case let quantity as HKQuantity:
                out[key] = .string(quantity.description)
            default:
                out[key] = .string(String(describing: value))
            }
        }
        return out
    }
}

struct SamplePayload: Codable, Sendable {
    var id: String
    var type: String
    /// "workout" for samples pulled by the per-workout backfill: the server keeps those for the
    /// full retention even when the metric is on the short raw window.
    var context: String?
    var kind: String
    var value: Double
    var unit: String?
    var valueLabel: String?
    var startDate: Date
    var endDate: Date
    var sourceName: String?
    var sourceBundleId: String?
    var device: String?
    var metadata: [String: MetaValue]?
}

struct DeletedSamples: Codable, Sendable {
    var type: String
    var ids: [String]
}

struct WorkoutPayload: Codable, Sendable {
    var id: String
    var activityType: UInt
    var activityTypeName: String
    var startDate: Date
    var endDate: Date
    var durationSec: Double
    var activeEnergyKcal: Double?
    var distanceM: Double?
    var avgHeartRate: Double?
    var minHeartRate: Double?
    var maxHeartRate: Double?
    var stepCount: Double?
    var avgRunningPowerW: Double?
    var avgSpeedMps: Double?
    var elevationAscendedM: Double?
    var isIndoor: Bool?
    var sourceName: String?
    var sourceBundleId: String?
    var device: String?
    var metadata: [String: MetaValue]?
}

/// One hour's aggregate, computed on-device with the same statistics query as the daily stats,
/// so iPhone/Watch/third-party overlap is already resolved.
struct HourlyStatPayload: Codable, Sendable {
    var date: String
    var hour: Int
    var type: String
    var unit: String
    var sum: Double?
    var avg: Double?
    var min: Double?
    var max: Double?
}

struct DailyStatPayload: Codable, Sendable {
    var date: String
    var type: String
    var unit: String
    var sum: Double?
    var avg: Double?
    var min: Double?
    var max: Double?
}

struct ActivitySummaryPayload: Codable, Sendable {
    var date: String
    var moveMode: String?
    var activeEnergyKcal: Double
    var activeEnergyGoalKcal: Double
    var moveMinutes: Double?
    var moveMinutesGoal: Double?
    var exerciseMinutes: Double
    var exerciseMinutesGoal: Double?
    var standHours: Double
    var standHoursGoal: Double?
}

/// HealthKit characteristics. Read once (they rarely change) and stored on the user document.
struct ProfilePayload: Codable, Sendable, Equatable {
    var dateOfBirth: String?
    var biologicalSex: String?
}

struct SyncRequest: Codable, Sendable {
    var timeZone: String = TimeZone.current.identifier
    var profile: ProfilePayload?
    var samples: [SamplePayload]?
    var deletedSamples: [DeletedSamples]?
    var workouts: [WorkoutPayload]?
    var deletedWorkoutIds: [String]?
    var dailyStats: [DailyStatPayload]?
    var hourlyStats: [HourlyStatPayload]?
    var activitySummaries: [ActivitySummaryPayload]?
}

struct SyncResponse: Codable, Sendable {
    struct Written: Codable, Sendable {
        var samples: Int
        var deletedSamples: Int
        var workouts: Int
        var deletedWorkouts: Int
        var days: Int
    }
    var ok: Bool
    var written: Written
}

/// What one sync did, reported to the server so the history survives a reinstall.
struct SyncLogPayload: Codable, Sendable {
    var startedAt: Date
    var durationMs: Double
    var trigger: String
    var samples: Int
    var deletedSamples: Int?
    var workouts: Int
    var days: Int
    var catalogVersion: String?
    var errors: [String]?
}

struct Profile: Codable, Sendable {
    var uid: String
    var timeZone: String?
    var lastSyncAt: String?
    var dateOfBirth: String?
    var biologicalSex: String?
}
