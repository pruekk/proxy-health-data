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
/**
 * How long raw samples live. `short` is for types that produce hundreds of samples a day —
 * keeping a year of those is expensive and the hourly and daily aggregates cover the long view.
 * Samples recorded during a workout are exempt and follow the normal retention either way.
 */
type Retention = 'standard' | 'short'

interface QuantityMetric {
  key: string
  identifier: string
  unit: string
  aggregation: Aggregation
  backfill?: Backfill
  retention?: Retention
  /** Worth an hourly bucket: the shape of the day is informative for these. */
  hourly?: boolean
}

interface CategoryMetric {
  key: string
  identifier: string
  backfill?: Backfill
  retention?: Retention
}

const q = (
  key: string,
  identifier: string,
  unit: string,
  aggregation: Aggregation,
  opts: Partial<QuantityMetric> = {},
): QuantityMetric => ({ key, identifier, unit, aggregation, ...opts })

const quantities: QuantityMetric[] = [
  // Activity
  q('stepCount', 'HKQuantityTypeIdentifierStepCount', 'count', 'cumulative', { hourly: true }),
  q('distanceWalkingRunning', 'HKQuantityTypeIdentifierDistanceWalkingRunning', 'm', 'cumulative', { hourly: true }),
  q('distanceCycling', 'HKQuantityTypeIdentifierDistanceCycling', 'm', 'cumulative'),
  q('distanceSwimming', 'HKQuantityTypeIdentifierDistanceSwimming', 'm', 'cumulative'),
  q('flightsClimbed', 'HKQuantityTypeIdentifierFlightsClimbed', 'count', 'cumulative'),
  q('activeEnergyBurned', 'HKQuantityTypeIdentifierActiveEnergyBurned', 'kcal', 'cumulative', { hourly: true }),
  q('basalEnergyBurned', 'HKQuantityTypeIdentifierBasalEnergyBurned', 'kcal', 'cumulative'),
  q('appleExerciseTime', 'HKQuantityTypeIdentifierAppleExerciseTime', 'min', 'cumulative'),
  q('appleStandTime', 'HKQuantityTypeIdentifierAppleStandTime', 'min', 'cumulative'),
  q('appleMoveTime', 'HKQuantityTypeIdentifierAppleMoveTime', 'min', 'cumulative'),
  q('timeInDaylight', 'HKQuantityTypeIdentifierTimeInDaylight', 'min', 'cumulative'),
  // Heart and lungs
  q('heartRate', 'HKQuantityTypeIdentifierHeartRate', 'count/min', 'discrete', { retention: 'short', hourly: true }),
  q('restingHeartRate', 'HKQuantityTypeIdentifierRestingHeartRate', 'count/min', 'discrete', { backfill: 'extended' }),
  q('walkingHeartRateAverage', 'HKQuantityTypeIdentifierWalkingHeartRateAverage', 'count/min', 'discrete', { backfill: 'extended' }),
  q('heartRateVariabilitySDNN', 'HKQuantityTypeIdentifierHeartRateVariabilitySDNN', 'ms', 'discrete', { backfill: 'extended' }),
  q('heartRateRecoveryOneMinute', 'HKQuantityTypeIdentifierHeartRateRecoveryOneMinute', 'count/min', 'discrete', { backfill: 'all' }),
  q('oxygenSaturation', 'HKQuantityTypeIdentifierOxygenSaturation', '%', 'discrete'),
  q('respiratoryRate', 'HKQuantityTypeIdentifierRespiratoryRate', 'count/min', 'discrete'),
  q('vo2Max', 'HKQuantityTypeIdentifierVO2Max', 'ml/(kg*min)', 'discrete', { backfill: 'all' }),
  q('bloodPressureSystolic', 'HKQuantityTypeIdentifierBloodPressureSystolic', 'mmHg', 'discrete', { backfill: 'extended' }),
  q('bloodPressureDiastolic', 'HKQuantityTypeIdentifierBloodPressureDiastolic', 'mmHg', 'discrete', { backfill: 'extended' }),
  // Body
  q('bodyMass', 'HKQuantityTypeIdentifierBodyMass', 'kg', 'discrete', { backfill: 'all' }),
  q('height', 'HKQuantityTypeIdentifierHeight', 'm', 'discrete', { backfill: 'all' }),
  q('bodyFatPercentage', 'HKQuantityTypeIdentifierBodyFatPercentage', '%', 'discrete', { backfill: 'all' }),
  q('leanBodyMass', 'HKQuantityTypeIdentifierLeanBodyMass', 'kg', 'discrete', { backfill: 'all' }),
  q('bodyMassIndex', 'HKQuantityTypeIdentifierBodyMassIndex', 'count', 'discrete', { backfill: 'all' }),
  q('waistCircumference', 'HKQuantityTypeIdentifierWaistCircumference', 'cm', 'discrete', { backfill: 'all' }),
  q('bodyTemperature', 'HKQuantityTypeIdentifierBodyTemperature', 'degC', 'discrete', { backfill: 'all' }),
  q('appleSleepingWristTemperature', 'HKQuantityTypeIdentifierAppleSleepingWristTemperature', 'degC', 'discrete', { backfill: 'extended' }),
  // Mobility and running form
  q('walkingSpeed', 'HKQuantityTypeIdentifierWalkingSpeed', 'm/s', 'discrete', { retention: 'short' }),
  q('walkingStepLength', 'HKQuantityTypeIdentifierWalkingStepLength', 'm', 'discrete', { retention: 'short' }),
  q('runningSpeed', 'HKQuantityTypeIdentifierRunningSpeed', 'm/s', 'discrete', { retention: 'short' }),
  q('runningPower', 'HKQuantityTypeIdentifierRunningPower', 'W', 'discrete', { retention: 'short' }),
  q('runningStrideLength', 'HKQuantityTypeIdentifierRunningStrideLength', 'm', 'discrete', { retention: 'short' }),
  q('runningGroundContactTime', 'HKQuantityTypeIdentifierRunningGroundContactTime', 'ms', 'discrete', { retention: 'short' }),
  q('runningVerticalOscillation', 'HKQuantityTypeIdentifierRunningVerticalOscillation', 'cm', 'discrete', { retention: 'short' }),
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
    /** Days of raw history kept for `retention: 'short'` metrics outside workouts. */
    shortRetentionDays: 7,
    /** Days of hourly buckets the app recomputes on every sync, for late-arriving samples. */
    hourlyRecomputeDays: 3,
  },
}

// Lets the app skip the download and the authorization check when nothing changed.
const version = createHash('sha256').update(JSON.stringify(body)).digest('hex').slice(0, 12)

export const catalog = { version, ...body }
export type Catalog = typeof catalog
