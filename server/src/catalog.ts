// The HealthKit catalog the iOS app syncs, served from here so adding a metric is a deploy
// instead of an App Store trip. The app keeps a built-in copy as a fallback and skips anything
// it cannot resolve (unknown identifier or unit), so a bad entry degrades rather than crashes.
//
// `identifier` is the raw HKQuantityTypeIdentifier / HKCategoryTypeIdentifier string, and `unit`
// must be one of the unit strings the app knows (see HealthCatalog.unit(from:)).

import { createHash } from 'node:crypto'

type Aggregation = 'cumulative' | 'discrete'
/** How far back the first sync of a metric reaches; anchors keep it current afterwards. */
type Backfill = 'standard' | 'extended' | 'all'

interface QuantityMetric {
  key: string
  identifier: string
  unit: string
  aggregation: Aggregation
  backfill?: Backfill
}

interface CategoryMetric {
  key: string
  identifier: string
  backfill?: Backfill
}

const q = (
  key: string,
  identifier: string,
  unit: string,
  aggregation: Aggregation,
  backfill?: Backfill,
): QuantityMetric => ({ key, identifier, unit, aggregation, ...(backfill ? { backfill } : {}) })

const quantities: QuantityMetric[] = [
  // Activity
  q('stepCount', 'HKQuantityTypeIdentifierStepCount', 'count', 'cumulative'),
  q('distanceWalkingRunning', 'HKQuantityTypeIdentifierDistanceWalkingRunning', 'm', 'cumulative'),
  q('distanceCycling', 'HKQuantityTypeIdentifierDistanceCycling', 'm', 'cumulative'),
  q('distanceSwimming', 'HKQuantityTypeIdentifierDistanceSwimming', 'm', 'cumulative'),
  q('flightsClimbed', 'HKQuantityTypeIdentifierFlightsClimbed', 'count', 'cumulative'),
  q('activeEnergyBurned', 'HKQuantityTypeIdentifierActiveEnergyBurned', 'kcal', 'cumulative'),
  q('basalEnergyBurned', 'HKQuantityTypeIdentifierBasalEnergyBurned', 'kcal', 'cumulative'),
  q('appleExerciseTime', 'HKQuantityTypeIdentifierAppleExerciseTime', 'min', 'cumulative'),
  q('appleStandTime', 'HKQuantityTypeIdentifierAppleStandTime', 'min', 'cumulative'),
  q('appleMoveTime', 'HKQuantityTypeIdentifierAppleMoveTime', 'min', 'cumulative'),
  q('timeInDaylight', 'HKQuantityTypeIdentifierTimeInDaylight', 'min', 'cumulative'),
  // Heart and lungs
  q('heartRate', 'HKQuantityTypeIdentifierHeartRate', 'count/min', 'discrete'),
  q('restingHeartRate', 'HKQuantityTypeIdentifierRestingHeartRate', 'count/min', 'discrete', 'extended'),
  q('walkingHeartRateAverage', 'HKQuantityTypeIdentifierWalkingHeartRateAverage', 'count/min', 'discrete', 'extended'),
  q('heartRateVariabilitySDNN', 'HKQuantityTypeIdentifierHeartRateVariabilitySDNN', 'ms', 'discrete', 'extended'),
  q('heartRateRecoveryOneMinute', 'HKQuantityTypeIdentifierHeartRateRecoveryOneMinute', 'count/min', 'discrete', 'all'),
  q('oxygenSaturation', 'HKQuantityTypeIdentifierOxygenSaturation', '%', 'discrete'),
  q('respiratoryRate', 'HKQuantityTypeIdentifierRespiratoryRate', 'count/min', 'discrete'),
  q('vo2Max', 'HKQuantityTypeIdentifierVO2Max', 'ml/(kg*min)', 'discrete', 'all'),
  q('bloodPressureSystolic', 'HKQuantityTypeIdentifierBloodPressureSystolic', 'mmHg', 'discrete', 'extended'),
  q('bloodPressureDiastolic', 'HKQuantityTypeIdentifierBloodPressureDiastolic', 'mmHg', 'discrete', 'extended'),
  // Body
  q('bodyMass', 'HKQuantityTypeIdentifierBodyMass', 'kg', 'discrete', 'all'),
  q('height', 'HKQuantityTypeIdentifierHeight', 'm', 'discrete', 'all'),
  q('bodyFatPercentage', 'HKQuantityTypeIdentifierBodyFatPercentage', '%', 'discrete', 'all'),
  q('leanBodyMass', 'HKQuantityTypeIdentifierLeanBodyMass', 'kg', 'discrete', 'all'),
  q('bodyMassIndex', 'HKQuantityTypeIdentifierBodyMassIndex', 'count', 'discrete', 'all'),
  q('waistCircumference', 'HKQuantityTypeIdentifierWaistCircumference', 'cm', 'discrete', 'all'),
  q('bodyTemperature', 'HKQuantityTypeIdentifierBodyTemperature', 'degC', 'discrete', 'all'),
  q('appleSleepingWristTemperature', 'HKQuantityTypeIdentifierAppleSleepingWristTemperature', 'degC', 'discrete', 'extended'),
  // Mobility and running form
  q('walkingSpeed', 'HKQuantityTypeIdentifierWalkingSpeed', 'm/s', 'discrete'),
  q('walkingStepLength', 'HKQuantityTypeIdentifierWalkingStepLength', 'm', 'discrete'),
  q('runningSpeed', 'HKQuantityTypeIdentifierRunningSpeed', 'm/s', 'discrete'),
  q('runningPower', 'HKQuantityTypeIdentifierRunningPower', 'W', 'discrete'),
  q('runningStrideLength', 'HKQuantityTypeIdentifierRunningStrideLength', 'm', 'discrete'),
  q('runningGroundContactTime', 'HKQuantityTypeIdentifierRunningGroundContactTime', 'ms', 'discrete'),
  q('runningVerticalOscillation', 'HKQuantityTypeIdentifierRunningVerticalOscillation', 'cm', 'discrete'),
]

const categories: CategoryMetric[] = [
  { key: 'sleepAnalysis', identifier: 'HKCategoryTypeIdentifierSleepAnalysis' },
  { key: 'mindfulSession', identifier: 'HKCategoryTypeIdentifierMindfulSession', backfill: 'extended' },
  { key: 'highHeartRateEvent', identifier: 'HKCategoryTypeIdentifierHighHeartRateEvent', backfill: 'extended' },
  { key: 'lowHeartRateEvent', identifier: 'HKCategoryTypeIdentifierLowHeartRateEvent', backfill: 'extended' },
  { key: 'irregularHeartRhythmEvent', identifier: 'HKCategoryTypeIdentifierIrregularHeartRhythmEvent', backfill: 'extended' },
  { key: 'lowCardioFitnessEvent', identifier: 'HKCategoryTypeIdentifierLowCardioFitnessEvent', backfill: 'extended' },
]

const body = {
  quantities,
  categories,
  // Pulled per workout so past runs stay reviewable without keeping every heart-rate sample.
  workoutDetailMetrics: ['heartRate', 'runningSpeed', 'cyclingSpeed'],
  // Characteristics are read once; without them VO2 max cannot be classified.
  characteristics: ['HKCharacteristicTypeIdentifierDateOfBirth', 'HKCharacteristicTypeIdentifierBiologicalSex'],
  sync: {
    extendedBackfillDays: 730,
    workoutDetailLimit: 40,
    recoveryTailSeconds: 600,
  },
}

// Lets the app skip the download and the authorization check when nothing changed.
const version = createHash('sha256').update(JSON.stringify(body)).digest('hex').slice(0, 12)

export const catalog = { version, ...body }
export type Catalog = typeof catalog
