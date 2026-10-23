import HealthKit

/// How a quantity is aggregated per day: summed (steps, energy) or averaged (heart rate, weight).
enum Aggregation: String, Sendable {
    case cumulative
    case discrete
}

struct QuantityMetric: @unchecked Sendable {
    /// Short key used by the server and Firestore, e.g. "stepCount".
    let key: String
    let identifier: HKQuantityTypeIdentifier
    let unit: HKUnit
    let aggregation: Aggregation

    var type: HKQuantityType { HKQuantityType(identifier) }
}

struct CategoryMetric: Sendable {
    let key: String
    let identifier: HKCategoryTypeIdentifier
    let label: @Sendable (Int) -> String?

    var type: HKCategoryType { HKCategoryType(identifier) }
}

/// Every HealthKit / Apple Fitness data type the app reads and syncs.
enum HealthCatalog {
    private static let bpm = HKUnit.count().unitDivided(by: .minute())
    private static let metersPerSecond = HKUnit.meter().unitDivided(by: .second())
    private static let vo2 = HKUnit.literUnit(with: .milli)
        .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))

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
        .init(key: "restingHeartRate", identifier: .restingHeartRate, unit: bpm, aggregation: .discrete),
        .init(key: "walkingHeartRateAverage", identifier: .walkingHeartRateAverage, unit: bpm, aggregation: .discrete),
        .init(key: "heartRateVariabilitySDNN", identifier: .heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), aggregation: .discrete),
        .init(key: "heartRateRecoveryOneMinute", identifier: .heartRateRecoveryOneMinute, unit: bpm, aggregation: .discrete),
        .init(key: "oxygenSaturation", identifier: .oxygenSaturation, unit: .percent(), aggregation: .discrete),
        .init(key: "respiratoryRate", identifier: .respiratoryRate, unit: bpm, aggregation: .discrete),
        .init(key: "vo2Max", identifier: .vo2Max, unit: vo2, aggregation: .discrete),
        .init(key: "bloodPressureSystolic", identifier: .bloodPressureSystolic, unit: .millimeterOfMercury(), aggregation: .discrete),
        .init(key: "bloodPressureDiastolic", identifier: .bloodPressureDiastolic, unit: .millimeterOfMercury(), aggregation: .discrete),
        // Body
        .init(key: "bodyMass", identifier: .bodyMass, unit: .gramUnit(with: .kilo), aggregation: .discrete),
        .init(key: "bodyFatPercentage", identifier: .bodyFatPercentage, unit: .percent(), aggregation: .discrete),
        .init(key: "leanBodyMass", identifier: .leanBodyMass, unit: .gramUnit(with: .kilo), aggregation: .discrete),
        .init(key: "bodyMassIndex", identifier: .bodyMassIndex, unit: .count(), aggregation: .discrete),
        .init(key: "appleSleepingWristTemperature", identifier: .appleSleepingWristTemperature, unit: .degreeCelsius(), aggregation: .discrete),
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
        .init(key: "mindfulSession", identifier: .mindfulSession, label: { _ in nil }),
        .init(key: "highHeartRateEvent", identifier: .highHeartRateEvent, label: { _ in nil }),
        .init(key: "lowHeartRateEvent", identifier: .lowHeartRateEvent, label: { _ in nil }),
        .init(key: "irregularHeartRhythmEvent", identifier: .irregularHeartRhythmEvent, label: { _ in nil }),
    ]

    static var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        quantities.forEach { types.insert($0.type) }
        categories.forEach { types.insert($0.type) }
        types.insert(HKObjectType.workoutType())
        types.insert(HKObjectType.activitySummaryType())
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
