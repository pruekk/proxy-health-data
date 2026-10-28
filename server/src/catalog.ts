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
 * Aggregate-only metrics are marked short too, so the raw samples uploaded before they stopped
 * being collected are swept rather than sitting for the full retention.
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
  /**
   * Whether individual samples are uploaded. Cumulative metrics arrive as tiny increments —
   * "7 steps at 01:23:45" — which no tool reads and which cost thousands of writes per workout.
   * They are synced as hourly and daily aggregates instead, already de-duplicated on the phone.
   */
  raw?: boolean
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
  q('stepCount', 'HKQuantityTypeIdentifierStepCount', 'count', 'cumulative', { raw: false, retention: 'short', hourly: true }),
  q('distanceWalkingRunning', 'HKQuantityTypeIdentifierDistanceWalkingRunning', 'm', 'cumulative', { raw: false, retention: 'short', hourly: true }),
  q('distanceCycling', 'HKQuantityTypeIdentifierDistanceCycling', 'm', 'cumulative', { raw: false, retention: 'short', hourly: true }),
  q('distanceSwimming', 'HKQuantityTypeIdentifierDistanceSwimming', 'm', 'cumulative', { raw: false, retention: 'short', hourly: true }),
  q('flightsClimbed', 'HKQuantityTypeIdentifierFlightsClimbed', 'count', 'cumulative', { raw: false, retention: 'short', hourly: true }),
  q('activeEnergyBurned', 'HKQuantityTypeIdentifierActiveEnergyBurned', 'kcal', 'cumulative', { raw: false, retention: 'short', hourly: true }),
  q('basalEnergyBurned', 'HKQuantityTypeIdentifierBasalEnergyBurned', 'kcal', 'cumulative', { raw: false, retention: 'short', hourly: true }),
  q('appleExerciseTime', 'HKQuantityTypeIdentifierAppleExerciseTime', 'min', 'cumulative', { raw: false, retention: 'short', hourly: true }),
  q('appleStandTime', 'HKQuantityTypeIdentifierAppleStandTime', 'min', 'cumulative', { raw: false, retention: 'short', hourly: true }),
  q('appleMoveTime', 'HKQuantityTypeIdentifierAppleMoveTime', 'min', 'cumulative', { raw: false, retention: 'short', hourly: true }),
  q('timeInDaylight', 'HKQuantityTypeIdentifierTimeInDaylight', 'min', 'cumulative', { raw: false, retention: 'short', hourly: true }),
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
  // Without an explicit window this fell back to the seven-day default, so a reinstall or a
  // first sync saw a week of nights while heart rate and HRV came back two years — which left
  // the coaching tools with no sleep baseline to compare a night against.
  { key: 'sleepAnalysis', identifier: 'HKCategoryTypeIdentifierSleepAnalysis', backfill: 'extended' },
  { key: 'mindfulSession', identifier: 'HKCategoryTypeIdentifierMindfulSession', backfill: 'extended' },
  { key: 'highHeartRateEvent', identifier: 'HKCategoryTypeIdentifierHighHeartRateEvent', backfill: 'extended' },
  { key: 'lowHeartRateEvent', identifier: 'HKCategoryTypeIdentifierLowHeartRateEvent', backfill: 'extended' },
  { key: 'irregularHeartRhythmEvent', identifier: 'HKCategoryTypeIdentifierIrregularHeartRhythmEvent', backfill: 'extended' },
  { key: 'lowCardioFitnessEvent', identifier: 'HKCategoryTypeIdentifierLowCardioFitnessEvent', backfill: 'extended' },
]

/**
 * What the app puts on screen. Here rather than in Swift so adding a metric is one deploy:
 * it syncs, it is stored, and it appears — without an Xcode build. Deliberately limited to
 * which rows exist and what they are called; colour, size and layout stay in the app.
 */
const display = {
  /** The "ร่างกาย" card, in order. */
  body: [
    { key: 'bodyMass', name: 'น้ำหนัก', unit: 'kg', decimals: 1, symbol: 'scalemass' },
    { key: 'height', name: 'ส่วนสูง', unit: 'm', decimals: 2, symbol: 'figure.stand' },
    { key: 'bodyMassIndex', name: 'BMI', decimals: 1, symbol: 'circle.dashed' },
    { key: 'bodyFatPercentage', name: 'ไขมัน', unit: '%', decimals: 1, scale: 100, symbol: 'drop' },
    { key: 'leanBodyMass', name: 'มวลไร้ไขมัน', unit: 'kg', decimals: 1, symbol: 'figure.arms.open' },
    { key: 'waistCircumference', name: 'รอบเอว', unit: 'cm', decimals: 1, symbol: 'ruler' },
  ],
  /** The two-up tiles under "หัวใจและการหายใจ". */
  vitals: [
    { key: 'heartRateVariabilitySDNN', name: 'HRV', unit: 'ms', decimals: 1, averageDays: 30 },
    { key: 'respiratoryRate', name: 'หายใจ', unit: '/นาที', decimals: 1 },
    { key: 'walkingHeartRateAverage', name: 'ชีพจรตอนเดิน', unit: 'bpm', decimals: 0 },
    { key: 'oxygenSaturation', name: 'ออกซิเจน', unit: '%', decimals: 0, scale: 100 },
  ],
  /** Rows in the coverage list on the history tab. */
  coverage: [
    { key: 'heartRate', name: 'ชีพจร', symbol: 'heart' },
    { key: 'heartRateVariabilitySDNN', name: 'HRV', symbol: 'waveform.path.ecg' },
    { key: 'restingHeartRate', name: 'ชีพจรขณะพัก', symbol: 'bed.double' },
    { key: 'sleepAnalysis', name: 'การนอน', symbol: 'moon.stars' },
    { key: 'bodyMass', name: 'น้ำหนักและองค์ประกอบร่างกาย', symbol: 'scalemass' },
    { key: 'vo2Max', name: 'VO₂ max', symbol: 'chart.line.uptrend.xyaxis' },
  ],
  /** Choices in the retention picker. */
  retentionOptions: [1, 2, 5],
}

/**
 * Body battery. Garmin's runs on beat-to-beat HRV all day, which Apple Watch does not expose, so
 * this approximates with heart rate against resting and the energy actually burned. Every
 * constant is here so it can be tuned with a deploy instead of a rebuild.
 */
const battery = {
  /** Returned per hour actually asleep. The level climbs through the night from wherever the
   *  evening left it rather than resetting, which is what the reference device does: a 40%
   *  bedtime and 6h19 of sleep wakes up at 78%. */
  chargePerSleepHour: 6,
  sleepTargetMinutes: 480,
  /** Drained every waking hour before any activity. */
  idleDrainPerHour: 1,
  /** Active kilocalories in an hour, divided by this, is the activity drain. */
  activeEnergyDivisor: 30,
  /** Heart rate this far above resting starts costing; the excess is divided by the next value. */
  hrStressOffset: 15,
  hrStressDivisor: 14,
  /** Returned per hour spent near resting heart rate with almost no movement. */
  restChargePerHour: 1.5,
  /** Daytime sleep charges at the same rate, but a nap cannot stand in for a night. */
  napMinMinutes: 20,
  napMaxCharge: 15,
  napDailyMaxCharge: 20,
  /** Nights simulated before today, so the level carried into this morning is itself earned. */
  historyDays: 7,
  /** Where the chain starts, before any history is known. */
  seedLevel: 50,
  min: 0,
  max: 100,
}

const body = {
  quantities,
  categories,
  // Pulled per workout so past runs stay reviewable without keeping every heart-rate sample.
  // Distance is aggregate-only day to day, but inside a workout the raw samples are what
  // per-kilometre splits are built from.
  workoutDetailMetrics: ['heartRate', 'runningSpeed', 'cyclingSpeed', 'distanceWalkingRunning'],
  // Characteristics are read once; without them VO2 max cannot be classified.
  characteristics: ['HKCharacteristicTypeIdentifierDateOfBirth', 'HKCharacteristicTypeIdentifierBiologicalSex'],
  display,
  battery,
  sync: {
    extendedBackfillDays: 730,
    workoutDetailLimit: 40,
    recoveryTailSeconds: 600,
    /** Days of raw history kept for `retention: 'short'` metrics outside workouts. */
    shortRetentionDays: 7,
    /** Days of hourly buckets the app recomputes on every sync, for late-arriving samples. */
    hourlyRecomputeDays: 3,
    /** Minimum gap between automatic syncs; a manual tap ignores it. */
    cooldownSeconds: 120,
    /** Samples read per anchored page, and per upload request. */
    pageSize: 2000,
    uploadChunk: 2000,
    /** How much the dashboard loads: days of daily aggregates, and list lengths. */
    dashboardDays: 90,
    workoutsLimit: 10,
    syncsLimit: 30,
    /** Seconds a dashboard load is reused before refetching. */
    dashboardCacheSeconds: 60,
    /** Recent workouts shown on the home screen. */
    recentWorkouts: 5,
  },
}

// Lets the app skip the download and the authorization check when nothing changed.
const version = createHash('sha256').update(JSON.stringify(body)).digest('hex').slice(0, 12)

export const catalog = { version, ...body }
export type Catalog = typeof catalog
