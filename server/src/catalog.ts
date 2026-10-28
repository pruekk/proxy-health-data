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
  /** Which retention group this belongs to; see `groups` below. */
  group?: GroupId
}

interface CategoryMetric {
  key: string
  identifier: string
  backfill?: Backfill
  retention?: Retention
  group?: GroupId
}

/**
 * Retention groups. Metrics are kept for different lengths because they behave differently:
 * raw heart rate arrives hundreds of times a day and is summarised hourly anyway, while a
 * weigh-in arrives monthly and is only worth anything as a multi-year line.
 *
 * Nothing is kept forever. This service is a copy — Apple Health holds the original — so every
 * group expires and a full re-sync brings back whatever Health still has.
 */
export type GroupId = 'raw' | 'recovery' | 'training' | 'body' | 'events'

const groups = [
  {
    id: 'raw' as const,
    name: 'ข้อมูลดิบความถี่สูง',
    summary: 'ชีพจร ความเร็ว',
    /** Windows in days: this group is measured in days, not years. */
    unit: 'days' as const,
    options: [7, 14, 30, 90],
    default: 7,
    note: 'ช่วงที่ออกกำลังกายไม่ถูกลบตามหน้าต่างนี้ แต่เก็บตามกลุ่มการซ้อม — หน้าต่างนี้คุมเฉพาะชีพจรระหว่างวันธรรมดา ซึ่งสรุปรายชั่วโมงเก็บแทนไว้แล้ว',
  },
  {
    id: 'recovery' as const,
    name: 'ฟื้นตัวและการนอน',
    summary: 'นอน HRV ชีพจรพัก',
    unit: 'years' as const,
    options: [1, 2, 5, 10],
    default: 5,
    note: 'เป็นฐานของคะแนนความพร้อมและค่าปกติทั้งหมด ยิ่งยาวยิ่งเทียบตัวเองได้แม่น และโตช้ามากเมื่อเทียบกับข้อมูลดิบ',
  },
  {
    id: 'training' as const,
    name: 'การซ้อมและกิจกรรม',
    summary: 'สรุปรายวัน · workout',
    unit: 'years' as const,
    options: [1, 2, 5, 10],
    default: 5,
    note: 'สรุปรายวันและรายชั่วโมงทั้งหมดอยู่ในกลุ่มนี้ รวมถึงชีพจรและความเร็วช่วงที่ออกกำลังกาย',
  },
  {
    id: 'body' as const,
    name: 'ร่างกายและความฟิต',
    summary: 'น้ำหนัก ไขมัน VO₂max',
    unit: 'years' as const,
    options: [1, 2, 5, 10],
    default: 10,
    note: 'ทั้งกลุ่มเล็กกว่าชีพจรวันเดียว · ชั่งเดือนละครั้งต้องเก็บหลายปีถึงจะเห็นแนวโน้ม',
  },
  {
    id: 'events' as const,
    name: 'เหตุการณ์และอื่น ๆ',
    summary: 'ชีพจรผิดปกติ การฝึกสติ',
    unit: 'years' as const,
    options: [1, 2, 5, 10],
    default: 10,
    note: 'นาน ๆ เกิดที แต่เป็นเรื่องที่อยากย้อนดูได้',
  },
]

const q = (
  key: string,
  identifier: string,
  unit: string,
  aggregation: Aggregation,
  opts: Partial<QuantityMetric> = {},
): QuantityMetric => ({ key, identifier, unit, aggregation, ...opts })

const quantities: QuantityMetric[] = [
  // Activity
  q('stepCount', 'HKQuantityTypeIdentifierStepCount', 'count', 'cumulative', { group: 'training', raw: false, retention: 'short', hourly: true }),
  q('distanceWalkingRunning', 'HKQuantityTypeIdentifierDistanceWalkingRunning', 'm', 'cumulative', { group: 'training', raw: false, retention: 'short', hourly: true }),
  q('distanceCycling', 'HKQuantityTypeIdentifierDistanceCycling', 'm', 'cumulative', { group: 'training', raw: false, retention: 'short', hourly: true }),
  q('distanceSwimming', 'HKQuantityTypeIdentifierDistanceSwimming', 'm', 'cumulative', { group: 'training', raw: false, retention: 'short', hourly: true }),
  q('flightsClimbed', 'HKQuantityTypeIdentifierFlightsClimbed', 'count', 'cumulative', { group: 'training', raw: false, retention: 'short', hourly: true }),
  q('activeEnergyBurned', 'HKQuantityTypeIdentifierActiveEnergyBurned', 'kcal', 'cumulative', { group: 'training', raw: false, retention: 'short', hourly: true }),
  q('basalEnergyBurned', 'HKQuantityTypeIdentifierBasalEnergyBurned', 'kcal', 'cumulative', { group: 'training', raw: false, retention: 'short', hourly: true }),
  q('appleExerciseTime', 'HKQuantityTypeIdentifierAppleExerciseTime', 'min', 'cumulative', { group: 'training', raw: false, retention: 'short', hourly: true }),
  q('appleStandTime', 'HKQuantityTypeIdentifierAppleStandTime', 'min', 'cumulative', { group: 'training', raw: false, retention: 'short', hourly: true }),
  q('appleMoveTime', 'HKQuantityTypeIdentifierAppleMoveTime', 'min', 'cumulative', { group: 'training', raw: false, retention: 'short', hourly: true }),
  q('timeInDaylight', 'HKQuantityTypeIdentifierTimeInDaylight', 'min', 'cumulative', { group: 'training', raw: false, retention: 'short', hourly: true }),
  // Heart and lungs
  q('heartRate', 'HKQuantityTypeIdentifierHeartRate', 'count/min', 'discrete', { group: 'raw', retention: 'short', hourly: true }),
  q('restingHeartRate', 'HKQuantityTypeIdentifierRestingHeartRate', 'count/min', 'discrete', { group: 'recovery', backfill: 'extended' }),
  q('walkingHeartRateAverage', 'HKQuantityTypeIdentifierWalkingHeartRateAverage', 'count/min', 'discrete', { group: 'recovery', backfill: 'extended' }),
  q('heartRateVariabilitySDNN', 'HKQuantityTypeIdentifierHeartRateVariabilitySDNN', 'ms', 'discrete', { group: 'recovery', backfill: 'extended' }),
  q('heartRateRecoveryOneMinute', 'HKQuantityTypeIdentifierHeartRateRecoveryOneMinute', 'count/min', 'discrete', { group: 'recovery', backfill: 'all' }),
  q('oxygenSaturation', 'HKQuantityTypeIdentifierOxygenSaturation', '%', 'discrete', { group: 'recovery' }),
  q('respiratoryRate', 'HKQuantityTypeIdentifierRespiratoryRate', 'count/min', 'discrete', { group: 'recovery' }),
  q('vo2Max', 'HKQuantityTypeIdentifierVO2Max', 'ml/(kg*min)', 'discrete', { group: 'body', backfill: 'all' }),
  q('bloodPressureSystolic', 'HKQuantityTypeIdentifierBloodPressureSystolic', 'mmHg', 'discrete', { group: 'body', backfill: 'extended' }),
  q('bloodPressureDiastolic', 'HKQuantityTypeIdentifierBloodPressureDiastolic', 'mmHg', 'discrete', { group: 'body', backfill: 'extended' }),
  // Body
  q('bodyMass', 'HKQuantityTypeIdentifierBodyMass', 'kg', 'discrete', { group: 'body', backfill: 'all' }),
  q('height', 'HKQuantityTypeIdentifierHeight', 'm', 'discrete', { group: 'body', backfill: 'all' }),
  q('bodyFatPercentage', 'HKQuantityTypeIdentifierBodyFatPercentage', '%', 'discrete', { group: 'body', backfill: 'all' }),
  q('leanBodyMass', 'HKQuantityTypeIdentifierLeanBodyMass', 'kg', 'discrete', { group: 'body', backfill: 'all' }),
  q('bodyMassIndex', 'HKQuantityTypeIdentifierBodyMassIndex', 'count', 'discrete', { group: 'body', backfill: 'all' }),
  q('waistCircumference', 'HKQuantityTypeIdentifierWaistCircumference', 'cm', 'discrete', { group: 'body', backfill: 'all' }),
  q('bodyTemperature', 'HKQuantityTypeIdentifierBodyTemperature', 'degC', 'discrete', { group: 'recovery', backfill: 'all' }),
  q('appleSleepingWristTemperature', 'HKQuantityTypeIdentifierAppleSleepingWristTemperature', 'degC', 'discrete', { group: 'recovery', backfill: 'extended' }),
  // Mobility and running form
  q('walkingSpeed', 'HKQuantityTypeIdentifierWalkingSpeed', 'm/s', 'discrete', { group: 'raw', retention: 'short' }),
  q('walkingStepLength', 'HKQuantityTypeIdentifierWalkingStepLength', 'm', 'discrete', { group: 'raw', retention: 'short' }),
  q('runningSpeed', 'HKQuantityTypeIdentifierRunningSpeed', 'm/s', 'discrete', { group: 'raw', retention: 'short' }),
  q('runningPower', 'HKQuantityTypeIdentifierRunningPower', 'W', 'discrete', { group: 'raw', retention: 'short' }),
  q('runningStrideLength', 'HKQuantityTypeIdentifierRunningStrideLength', 'm', 'discrete', { group: 'raw', retention: 'short' }),
  q('runningGroundContactTime', 'HKQuantityTypeIdentifierRunningGroundContactTime', 'ms', 'discrete', { group: 'raw', retention: 'short' }),
  q('runningVerticalOscillation', 'HKQuantityTypeIdentifierRunningVerticalOscillation', 'cm', 'discrete', { group: 'raw', retention: 'short' }),
]

const categories: CategoryMetric[] = [
  // Without an explicit window this fell back to the seven-day default, so a reinstall or a
  // first sync saw a week of nights while heart rate and HRV came back two years — which left
  // the coaching tools with no sleep baseline to compare a night against.
  { key: 'sleepAnalysis', identifier: 'HKCategoryTypeIdentifierSleepAnalysis', backfill: 'extended', group: 'recovery' },
  { key: 'mindfulSession', identifier: 'HKCategoryTypeIdentifierMindfulSession', backfill: 'extended', group: 'events' },
  { key: 'highHeartRateEvent', identifier: 'HKCategoryTypeIdentifierHighHeartRateEvent', backfill: 'extended', group: 'events' },
  { key: 'lowHeartRateEvent', identifier: 'HKCategoryTypeIdentifierLowHeartRateEvent', backfill: 'extended', group: 'events' },
  { key: 'irregularHeartRhythmEvent', identifier: 'HKCategoryTypeIdentifierIrregularHeartRhythmEvent', backfill: 'extended', group: 'events' },
  { key: 'lowCardioFitnessEvent', identifier: 'HKCategoryTypeIdentifierLowCardioFitnessEvent', backfill: 'extended', group: 'events' },
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

/**
 * Training load, as an acute-to-chronic workload ratio. The chronic window grows with the
 * history available rather than being fixed: someone four weeks into running has no ninety-day
 * normal to be compared against, and comparing them to one makes every week look like a spike.
 */
const load = {
  acuteDays: 7,
  /** Shortest chronic window worth comparing against — the sports-science convention. */
  minChronicDays: 28,
  /** And the longest, once there is enough history to fill it. */
  maxChronicDays: 90,
}

/**
 * Heart-rate zones, from the heart rate actually recorded rather than an age formula. Percentages
 * are of heart rate reserve (Karvonen), which accounts for resting pulse instead of treating
 * everyone with the same maximum as identical.
 */
const heartRate = {
  /** Workouts with a maximum reading needed before the observed maximum is trusted. */
  minWorkoutsForMax: 5,
  /** Days of resting pulse taken for the median the zones are built on. */
  restingMedianDays: 30,
  zones: [
    { zone: 1, name: 'ฟื้นตัว', from: 0.5, to: 0.6 },
    { zone: 2, name: 'เบา (แอโรบิก)', from: 0.6, to: 0.7 },
    { zone: 3, name: 'ปานกลาง', from: 0.7, to: 0.8 },
    { zone: 4, name: 'หนัก (threshold)', from: 0.8, to: 0.9 },
    { zone: 5, name: 'สูงสุด', from: 0.9, to: 1 },
  ],
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
  retentionGroups: groups,
  load,
  heartRate,
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
