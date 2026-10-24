import HealthKit

/// How a quantity is aggregated per day: summed (steps, energy) or averaged (heart rate, weight).
enum Aggregation: String, Sendable {
    case cumulative
    case discrete
}

/// How far back the *first* sync of a metric reaches. Anchored queries keep everything current
/// afterwards, so this only sizes the initial pull.
enum Backfill: Sendable {
    /// The window from Settings (7 days by default). For types that produce samples all day.
    case standard
    /// Two years. Affordable for types recorded a few times a week at most.
    case extended
    /// Everything HealthKit holds. Only for types that produce a handful of samples a month —
    /// VO2 max stopped updating in Aug 2024, which `.extended` misses by 57 days.
    case all
}

struct QuantityMetric: @unchecked Sendable {
    /// Short key used by the server and Firestore, e.g. "stepCount".
    let key: String
    let identifier: HKQuantityTypeIdentifier
    let unit: HKUnit
    let aggregation: Aggregation
    var backfill: Backfill = .standard

    var type: HKQuantityType { HKQuantityType(identifier) }
}

struct CategoryMetric: Sendable {
    let key: String
    let identifier: HKCategoryTypeIdentifier
    let label: @Sendable (Int) -> String?
    var backfill: Backfill = .standard

    var type: HKCategoryType { HKCategoryType(identifier) }
}

/// Every HealthKit / Apple Fitness data type the app reads and syncs.
enum HealthCatalog {
    /// Days of history pulled for `.extended` metrics on the first sync. The server catalog can
    /// override it without a rebuild.
    static var extendedBackfillDays: Int { CatalogStore.cached?.sync?.extendedBackfillDays ?? 730 }

    private static let bpm = HKUnit.count().unitDivided(by: .minute())
    private static let metersPerSecond = HKUnit.meter().unitDivided(by: .second())
    private static let vo2 = HKUnit.literUnit(with: .milli)
        .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))

    /// Built-in copy, used until the server catalog has been fetched at least once.
    static let quantities: [QuantityMetric] = [
        // Activity (Apple Fitness rings and movement)
        .init(key: "stepCount", identifier: .stepCount, unit: .count(), aggregation: .cumulative),
        .init(key: "distanceWalkingRunning", identifier: .distanceWalkingRunning, unit: .meter(), aggregation: .cumulative),
        .init(key: "distanceCycling", identifier: .distanceCycling, unit: .meter(), aggregation: .cumulative),
        .init(key: "distanceSwimming", identifier: .distanceSwimming, unit: .meter(), aggregation: .cumulative),
        .init(key: "flightsClimbed", identifier: .flightsClimbed, unit: .count(), aggregation: .cumulative),
        .init(key: "activeEnergyBurned", identifier: .activeEnergyBurned, unit: .kilocalorie(), aggregation: .cumulative),
        .init(key: "basalEnergyBurned", identifier: .basalEnergyBurned, unit: .kilocalorie(), aggregation: .cumulative),
        .init(key: "appleExerciseTime", identifier: .appleExerciseTime, unit: .minute(), aggregation: .cumulative),
        .init(key: "appleStandTime", identifier: .appleStandTime, unit: .minute(), aggregation: .cumulative),
        .init(key: "appleMoveTime", identifier: .appleMoveTime, unit: .minute(), aggregation: .cumulative),
        .init(key: "timeInDaylight", identifier: .timeInDaylight, unit: .minute(), aggregation: .cumulative),
        // Heart and lungs
        .init(key: "heartRate", identifier: .heartRate, unit: bpm, aggregation: .discrete),
        .init(key: "restingHeartRate", identifier: .restingHeartRate, unit: bpm, aggregation: .discrete, backfill: .extended),
        .init(key: "walkingHeartRateAverage", identifier: .walkingHeartRateAverage, unit: bpm, aggregation: .discrete, backfill: .extended),
        .init(key: "heartRateVariabilitySDNN", identifier: .heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), aggregation: .discrete, backfill: .extended),
        .init(key: "heartRateRecoveryOneMinute", identifier: .heartRateRecoveryOneMinute, unit: bpm, aggregation: .discrete, backfill: .all),
        .init(key: "oxygenSaturation", identifier: .oxygenSaturation, unit: .percent(), aggregation: .discrete),
        .init(key: "respiratoryRate", identifier: .respiratoryRate, unit: bpm, aggregation: .discrete),
        .init(key: "vo2Max", identifier: .vo2Max, unit: vo2, aggregation: .discrete, backfill: .all),
        .init(key: "bloodPressureSystolic", identifier: .bloodPressureSystolic, unit: .millimeterOfMercury(), aggregation: .discrete, backfill: .extended),
        .init(key: "bloodPressureDiastolic", identifier: .bloodPressureDiastolic, unit: .millimeterOfMercury(), aggregation: .discrete, backfill: .extended),
        // Body
        .init(key: "bodyMass", identifier: .bodyMass, unit: .gramUnit(with: .kilo), aggregation: .discrete, backfill: .all),
        .init(key: "height", identifier: .height, unit: .meter(), aggregation: .discrete, backfill: .all),
        .init(key: "bodyFatPercentage", identifier: .bodyFatPercentage, unit: .percent(), aggregation: .discrete, backfill: .all),
        .init(key: "leanBodyMass", identifier: .leanBodyMass, unit: .gramUnit(with: .kilo), aggregation: .discrete, backfill: .all),
        .init(key: "bodyMassIndex", identifier: .bodyMassIndex, unit: .count(), aggregation: .discrete, backfill: .all),
        .init(key: "waistCircumference", identifier: .waistCircumference, unit: .meterUnit(with: .centi), aggregation: .discrete, backfill: .all),
        .init(key: "bodyTemperature", identifier: .bodyTemperature, unit: .degreeCelsius(), aggregation: .discrete, backfill: .extended),
        .init(key: "appleSleepingWristTemperature", identifier: .appleSleepingWristTemperature, unit: .degreeCelsius(), aggregation: .discrete, backfill: .extended),
        // Mobility and running form
        .init(key: "walkingSpeed", identifier: .walkingSpeed, unit: metersPerSecond, aggregation: .discrete),
        .init(key: "walkingStepLength", identifier: .walkingStepLength, unit: .meter(), aggregation: .discrete),
        .init(key: "runningSpeed", identifier: .runningSpeed, unit: metersPerSecond, aggregation: .discrete),
        .init(key: "runningPower", identifier: .runningPower, unit: .watt(), aggregation: .discrete),
        .init(key: "runningStrideLength", identifier: .runningStrideLength, unit: .meter(), aggregation: .discrete),
        .init(key: "runningGroundContactTime", identifier: .runningGroundContactTime, unit: .secondUnit(with: .milli), aggregation: .discrete),
        .init(key: "runningVerticalOscillation", identifier: .runningVerticalOscillation, unit: .meterUnit(with: .centi), aggregation: .discrete),
    ]

    static let categories: [CategoryMetric] = [
        .init(key: "sleepAnalysis", identifier: .sleepAnalysis, label: { sleepLabel($0) }),
        .init(key: "mindfulSession", identifier: .mindfulSession, label: { _ in nil }, backfill: .extended),
        .init(key: "highHeartRateEvent", identifier: .highHeartRateEvent, label: { _ in nil }, backfill: .extended),
        .init(key: "lowHeartRateEvent", identifier: .lowHeartRateEvent, label: { _ in nil }, backfill: .extended),
        .init(key: "irregularHeartRhythmEvent", identifier: .irregularHeartRhythmEvent, label: { _ in nil }, backfill: .extended),
        // Apple's "your cardio fitness is low" notification.
        .init(key: "lowCardioFitnessEvent", identifier: .lowCardioFitnessEvent, label: { _ in nil }, backfill: .extended),
    ]

    /// Unit strings the app accepts from the server catalog. `HKUnit(from:)` raises an
    /// Objective-C exception on anything malformed — which Swift cannot catch — so resolution
    /// goes through this list and an unknown unit skips the metric instead of crashing.
    static func unit(named name: String) -> HKUnit? {
        switch name {
        case "count": .count()
        case "count/min": bpm
        case "m": .meter()
        case "cm": .meterUnit(with: .centi)
        case "km": .meterUnit(with: .kilo)
        case "m/s": metersPerSecond
        case "kg": .gramUnit(with: .kilo)
        case "g": .gram()
        case "kcal": .kilocalorie()
        case "min": .minute()
        case "s": .second()
        case "ms": .secondUnit(with: .milli)
        case "hr": .hour()
        case "%": .percent()
        case "degC": .degreeCelsius()
        case "degF": .degreeFahrenheit()
        case "W": .watt()
        case "mmHg": .millimeterOfMercury()
        case "ml/(kg*min)": vo2
        case "L": .liter()
        case "mL": .literUnit(with: .milli)
        case "mg/dL": HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))
        case "dBASPL": .decibelAWeightedSoundPressureLevel()
        default: nil
        }
    }

    /// Metrics pulled per workout for after-the-fact review: heart rate and pace.
    static var workoutDetailMetrics: [QuantityMetric] {
        let keys = CatalogStore.cached?.workoutDetailMetrics ?? ["heartRate", "runningSpeed", "cyclingSpeed"]
        return effective.quantities.filter { keys.contains($0.key) }
    }

    /// Metrics actually synced: the downloaded catalog when there is one, the built-in list
    /// otherwise. Falling back keeps a first launch and an offline launch working.
    static var effective: (quantities: [QuantityMetric], categories: [CategoryMetric], skipped: [String]) {
        guard let remote = CatalogStore.cached else { return (quantities, categories, []) }
        let resolved = remote.resolved()
        guard !resolved.quantities.isEmpty else { return (quantities, categories, resolved.skipped) }
        return resolved
    }

    static var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        let active = effective
        active.quantities.forEach { types.insert($0.type) }
        active.categories.forEach { types.insert($0.type) }
        types.insert(HKObjectType.workoutType())
        types.insert(HKObjectType.activitySummaryType())
        // Needed to interpret VO2 max: Apple's cardio fitness levels are age- and sex-banded.
        if let remote = CatalogStore.cached, !remote.characteristicTypes.isEmpty {
            remote.characteristicTypes.forEach { types.insert($0) }
        } else {
            types.insert(HKCharacteristicType(.dateOfBirth))
            types.insert(HKCharacteristicType(.biologicalSex))
        }
        return types
    }

    static func sleepLabel(_ value: Int) -> String? {
        switch HKCategoryValueSleepAnalysis(rawValue: value) {
        case .inBed: "inBed"
        case .asleepUnspecified: "asleepUnspecified"
        case .awake: "awake"
        case .asleepCore: "asleepCore"
        case .asleepDeep: "asleepDeep"
        case .asleepREM: "asleepREM"
        default: nil
        }
    }
}

extension HKWorkoutActivityType {
    /// Stable camelCase name for the server, e.g. "running", "traditionalStrengthTraining".
    var name: String {
        switch self {
        case .running: "running"
        case .walking: "walking"
        case .hiking: "hiking"
        case .cycling: "cycling"
        case .swimming: "swimming"
        case .rowing: "rowing"
        case .elliptical: "elliptical"
        case .stairClimbing: "stairClimbing"
        case .stairs: "stairs"
        case .stepTraining: "stepTraining"
        case .traditionalStrengthTraining: "traditionalStrengthTraining"
        case .functionalStrengthTraining: "functionalStrengthTraining"
        case .coreTraining: "coreTraining"
        case .highIntensityIntervalTraining: "highIntensityIntervalTraining"
        case .crossTraining: "crossTraining"
        case .mixedCardio: "mixedCardio"
        case .jumpRope: "jumpRope"
        case .yoga: "yoga"
        case .pilates: "pilates"
        case .mindAndBody: "mindAndBody"
        case .flexibility: "flexibility"
        case .cooldown: "cooldown"
        case .dance: "dance"
        case .cardioDance: "cardioDance"
        case .socialDance: "socialDance"
        case .barre: "barre"
        case .kickboxing: "kickboxing"
        case .boxing: "boxing"
        case .martialArts: "martialArts"
        case .tennis: "tennis"
        case .badminton: "badminton"
        case .tableTennis: "tableTennis"
        case .pickleball: "pickleball"
        case .soccer: "soccer"
        case .basketball: "basketball"
        case .volleyball: "volleyball"
        case .golf: "golf"
        case .climbing: "climbing"
        case .paddleSports: "paddleSports"
        case .surfingSports: "surfingSports"
        case .snowSports: "snowSports"
        case .downhillSkiing: "downhillSkiing"
        case .snowboarding: "snowboarding"
        case .crossCountrySkiing: "crossCountrySkiing"
        case .swimBikeRun: "swimBikeRun"
        case .transition: "transition"
        case .wheelchairWalkPace: "wheelchairWalkPace"
        case .wheelchairRunPace: "wheelchairRunPace"
        case .other: "other"
        default: "type\(rawValue)"
        }
    }
}
