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
    }

    struct Category: Codable, Sendable {
        let key: String
        let identifier: String
        var backfill: String?
    }

    struct Sync: Codable, Sendable {
        var extendedBackfillDays: Int?
        var workoutDetailLimit: Int?
        var recoveryTailSeconds: Double?
        var shortRetentionDays: Int?
        var hourlyRecomputeDays: Int?
    }

    let version: String
    var quantities: [Quantity]
    var categories: [Category]
    var workoutDetailMetrics: [String]?
    var characteristics: [String]?
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
