import Foundation
import HealthKit

/// The metric list the app syncs, downloaded from the server so adding a metric is a deploy
/// rather than a rebuild. `HealthCatalog` stays in the binary as the fallback for a first run,
/// an offline launch, or a server that is unreachable.
///
/// Anything the device cannot resolve — an identifier this iOS version does not know, a unit the
/// app cannot parse — is skipped and reported, so a bad catalog entry degrades one metric instead
/// of breaking the sync.
struct RemoteCatalog: Codable, Sendable {
    struct Quantity: Codable, Sendable {
        let key: String
        let identifier: String
        let unit: String
        let aggregation: String
        var backfill: String?
        var retention: String?
        var hourly: Bool?
        var raw: Bool?
        /// Which retention group the metric belongs to.
        var group: String?
    }

    struct Category: Codable, Sendable {
        let key: String
        let identifier: String
        var backfill: String?
        var group: String?
    }

    /// Which rows appear on screen and what they are called. Server-side so a new metric shows
    /// up with a deploy rather than an Xcode build.
    struct Row: Codable, Sendable, Identifiable {
        let key: String
        let name: String
        var unit: String?
        var decimals: Int?
        var scale: Double?
        var symbol: String?
        var averageDays: Int?

        var id: String { key }
    }

    struct Display: Codable, Sendable {
        var body: [Row] = []
        var vitals: [Row] = []
        var coverage: [Row] = []
        var retentionOptions: [Int] = [1, 2, 5]
    }

    struct Battery: Codable, Sendable {
        var sleepTargetMinutes: Int?
    }

    struct Sync: Codable, Sendable {
        var extendedBackfillDays: Int?
        var workoutDetailLimit: Int?
        var recoveryTailSeconds: Double?
        var shortRetentionDays: Int?
        var hourlyRecomputeDays: Int?
        var cooldownSeconds: Double?
        var pageSize: Int?
        var uploadChunk: Int?
        var dashboardDays: Int?
        var workoutsLimit: Int?
        var syncsLimit: Int?
        var dashboardCacheSeconds: Double?
        var recentWorkouts: Int?
    }

    let version: String
    var quantities: [Quantity]
    var categories: [Category]
    var workoutDetailMetrics: [String]?
    var characteristics: [String]?
    var display: Display?
    var battery: Battery?
    var sync: Sync?
}

extension RemoteCatalog {
    /// Metrics this device can actually read. Unresolvable entries are returned separately so the
    /// sync log can show them rather than failing silently.
    func resolved() -> (quantities: [QuantityMetric], categories: [CategoryMetric], skipped: [String]) {
        var resolvedQuantities: [QuantityMetric] = []
        var resolvedCategories: [CategoryMetric] = []
        var skipped: [String] = []

        for metric in quantities {
            guard HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: metric.identifier)) != nil else {
                skipped.append("\(metric.key) (unknown identifier)")
                continue
            }
            guard let unit = HealthCatalog.unit(named: metric.unit) else {
                skipped.append("\(metric.key) (unknown unit \(metric.unit))")
                continue
            }
            resolvedQuantities.append(
                QuantityMetric(
                    key: metric.key,
                    identifier: HKQuantityTypeIdentifier(rawValue: metric.identifier),
                    unit: unit,
                    aggregation: metric.aggregation == "cumulative" ? .cumulative : .discrete,
                    backfill: Backfill(name: metric.backfill),
                    uploadsRaw: metric.raw ?? true
                )
            )
        }

        for metric in categories {
            guard HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: metric.identifier)) != nil else {
                skipped.append("\(metric.key) (unknown identifier)")
                continue
            }
            // Sleep is the only category whose raw value carries meaning worth naming.
            let isSleep = metric.key == "sleepAnalysis"
            let label: @Sendable (Int) -> String? = { value in
                isSleep ? HealthCatalog.sleepLabel(value) : nil
            }
            resolvedCategories.append(
                CategoryMetric(
                    key: metric.key,
                    identifier: HKCategoryTypeIdentifier(rawValue: metric.identifier),
                    label: label,
                    backfill: Backfill(name: metric.backfill)
                )
            )
        }
        return (resolvedQuantities, resolvedCategories, skipped)
    }

    var characteristicTypes: [HKObjectType] {
        (characteristics ?? []).compactMap {
            HKObjectType.characteristicType(forIdentifier: HKCharacteristicTypeIdentifier(rawValue: $0))
        }
    }
}

extension Backfill {
    init(name: String?) {
        switch name {
        case "all": self = .all
        case "extended": self = .extended
        default: self = .standard
        }
    }
}

extension RemoteCatalog.Display {
    /// Used until the catalog has been fetched once.
    static let fallback = RemoteCatalog.Display(
        body: [
            .init(key: "bodyMass", name: "น้ำหนัก", unit: "kg", decimals: 1, symbol: "scalemass"),
            .init(key: "height", name: "ส่วนสูง", unit: "m", decimals: 2, symbol: "figure.stand"),
            .init(key: "bodyMassIndex", name: "BMI", decimals: 1, symbol: "circle.dashed"),
            .init(key: "bodyFatPercentage", name: "ไขมัน", unit: "%", decimals: 1, scale: 100, symbol: "drop"),
            .init(key: "leanBodyMass", name: "มวลไร้ไขมัน", unit: "kg", decimals: 1, symbol: "figure.arms.open"),
            .init(key: "waistCircumference", name: "รอบเอว", unit: "cm", decimals: 1, symbol: "ruler"),
        ],
        vitals: [
            .init(key: "heartRateVariabilitySDNN", name: "HRV", unit: "ms", decimals: 1, averageDays: 30),
            .init(key: "respiratoryRate", name: "หายใจ", unit: "/นาที", decimals: 1),
            .init(key: "walkingHeartRateAverage", name: "ชีพจรตอนเดิน", unit: "bpm", decimals: 0),
            .init(key: "oxygenSaturation", name: "ออกซิเจน", unit: "%", decimals: 0, scale: 100),
        ],
        coverage: [
            .init(key: "heartRate", name: "ชีพจร", symbol: "heart"),
            .init(key: "heartRateVariabilitySDNN", name: "HRV", symbol: "waveform.path.ecg"),
            .init(key: "restingHeartRate", name: "ชีพจรขณะพัก", symbol: "bed.double"),
            .init(key: "sleepAnalysis", name: "การนอน", symbol: "moon.stars"),
            .init(key: "bodyMass", name: "น้ำหนักและองค์ประกอบร่างกาย", symbol: "scalemass"),
            .init(key: "vo2Max", name: "VO₂ max", symbol: "chart.line.uptrend.xyaxis"),
        ]
    )
}

enum AppConfig {
    static var display: RemoteCatalog.Display { CatalogStore.cached?.display ?? .fallback }
    static var sync: RemoteCatalog.Sync { CatalogStore.cached?.sync ?? RemoteCatalog.Sync() }

    static var cooldownSeconds: TimeInterval { sync.cooldownSeconds ?? 120 }
    static var pageSize: Int { sync.pageSize ?? 2000 }
    static var uploadChunk: Int { sync.uploadChunk ?? 2000 }
    static var dashboardDays: Int { sync.dashboardDays ?? 90 }
    static var workoutsLimit: Int { sync.workoutsLimit ?? 10 }
    static var syncsLimit: Int { sync.syncsLimit ?? 30 }
    static var dashboardCacheSeconds: TimeInterval { sync.dashboardCacheSeconds ?? 60 }
    static var recentWorkouts: Int { sync.recentWorkouts ?? 5 }
    static var sleepTargetMinutes: Int { CatalogStore.cached?.battery?.sleepTargetMinutes ?? 480 }
    static var shortRetentionDays: Int { sync.shortRetentionDays ?? 7 }

    /// Metric keys belonging to a retention group, from the catalog.
    static func metricKeys(in group: String) -> Set<String> {
        guard let catalog = CatalogStore.cached else { return [] }
        let quantities = catalog.quantities.filter { ($0.group ?? "training") == group }.map(\.key)
        let categories = catalog.categories.filter { ($0.group ?? "training") == group }.map(\.key)
        return Set(quantities + categories)
    }

    /// Metrics whose raw samples only live for a few days. Taken from the catalog so the
    /// coverage list stays true after a retention change on the server.
    static var shortRetentionKeys: Set<String> {
        guard let quantities = CatalogStore.cached?.quantities else {
            return ["heartRate", "runningSpeed", "walkingSpeed"]
        }
        return Set(quantities.filter { $0.retention == "short" }.map(\.key))
    }
}

/// Stores the downloaded catalog and remembers which read types have been authorised, so a
/// catalog that gains a metric triggers one permission prompt instead of silently reading nothing.
enum CatalogStore {
    private static let defaults = UserDefaults.standard
    private static let catalogKey = "catalog.payload"
    private static let authorizedKey = "catalog.authorizedTypes"

    static var cached: RemoteCatalog? {
        guard let data = defaults.data(forKey: catalogKey) else { return nil }
        return try? JSONDecoder().decode(RemoteCatalog.self, from: data)
    }

    static func save(_ catalog: RemoteCatalog) {
        guard let data = try? JSONEncoder().encode(catalog) else { return }
        defaults.set(data, forKey: catalogKey)
    }

    /// Identifiers already passed to `requestAuthorization`. iOS only prompts for undetermined
    /// types, so re-requesting when the set grows costs nothing for types already decided.
    static var authorizedTypes: Set<String> {
        get { Set(defaults.stringArray(forKey: authorizedKey) ?? []) }
        set { defaults.set([String](newValue).sorted(), forKey: authorizedKey) }
    }
}
