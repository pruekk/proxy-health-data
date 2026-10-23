import { t, type Static } from 'elysia'

// Short HealthKit keys, e.g. "stepCount", "heartRate", "sleepAnalysis". Also used as Firestore doc ids.
const MetricKey = t.String({ pattern: '^[A-Za-z0-9_]{1,80}$' })
// HealthKit object UUIDs.
const ObjectId = t.String({ pattern: '^[A-Za-z0-9-]{1,64}$' })
const DateKey = t.String({ pattern: '^\\d{4}-\\d{2}-\\d{2}$' })
const IsoDate = t.String({ minLength: 10, maxLength: 40 })
const Metadata = t.Record(t.String(), t.Union([t.String(), t.Number(), t.Boolean()]))

export const SampleInput = t.Object({
  id: ObjectId,
  type: MetricKey,
  kind: t.Union([t.Literal('quantity'), t.Literal('category')]),
  value: t.Number(),
  unit: t.Optional(t.String()),
  valueLabel: t.Optional(t.String()),
  startDate: IsoDate,
  endDate: IsoDate,
  sourceName: t.Optional(t.String()),
  sourceBundleId: t.Optional(t.String()),
  device: t.Optional(t.String()),
  metadata: t.Optional(Metadata),
})

export const WorkoutInput = t.Object({
  id: ObjectId,
  activityType: t.Number(),
  activityTypeName: t.String(),
  startDate: IsoDate,
  endDate: IsoDate,
  durationSec: t.Number(),
  activeEnergyKcal: t.Optional(t.Number()),
  distanceM: t.Optional(t.Number()),
  avgHeartRate: t.Optional(t.Number()),
  minHeartRate: t.Optional(t.Number()),
  maxHeartRate: t.Optional(t.Number()),
  stepCount: t.Optional(t.Number()),
  avgRunningPowerW: t.Optional(t.Number()),
  avgSpeedMps: t.Optional(t.Number()),
  elevationAscendedM: t.Optional(t.Number()),
  isIndoor: t.Optional(t.Boolean()),
  sourceName: t.Optional(t.String()),
  sourceBundleId: t.Optional(t.String()),
  device: t.Optional(t.String()),
  metadata: t.Optional(Metadata),
})

// One day's aggregate for one metric, computed on-device with HKStatisticsCollectionQuery
// (which de-duplicates overlapping iPhone/Watch samples).
export const DailyStatInput = t.Object({
  date: DateKey,
  type: MetricKey,
  unit: t.String(),
  sum: t.Optional(t.Number()),
  avg: t.Optional(t.Number()),
  min: t.Optional(t.Number()),
  max: t.Optional(t.Number()),
})

// Apple Fitness activity rings for one day.
export const ActivitySummaryInput = t.Object({
  date: DateKey,
  moveMode: t.Optional(t.Union([t.Literal('activeEnergy'), t.Literal('moveTime')])),
  activeEnergyKcal: t.Number(),
  activeEnergyGoalKcal: t.Number(),
  moveMinutes: t.Optional(t.Number()),
  moveMinutesGoal: t.Optional(t.Number()),
  exerciseMinutes: t.Number(),
  exerciseMinutesGoal: t.Optional(t.Number()),
  standHours: t.Number(),
  standHoursGoal: t.Optional(t.Number()),
})

export const SyncBody = t.Object({
  timeZone: t.Optional(t.String({ maxLength: 64 })),
  samples: t.Optional(t.Array(SampleInput, { maxItems: 5000 })),
  deletedSamples: t.Optional(
    t.Array(t.Object({ type: MetricKey, ids: t.Array(ObjectId, { maxItems: 5000 }) }), { maxItems: 200 }),
  ),
  workouts: t.Optional(t.Array(WorkoutInput, { maxItems: 1000 })),
  deletedWorkoutIds: t.Optional(t.Array(ObjectId, { maxItems: 1000 })),
  dailyStats: t.Optional(t.Array(DailyStatInput, { maxItems: 10000 })),
  activitySummaries: t.Optional(t.Array(ActivitySummaryInput, { maxItems: 1000 })),
})

export type SampleInput = Static<typeof SampleInput>
export type WorkoutInput = Static<typeof WorkoutInput>
export type DailyStatInput = Static<typeof DailyStatInput>
export type ActivitySummaryInput = Static<typeof ActivitySummaryInput>
export type SyncBody = Static<typeof SyncBody>
