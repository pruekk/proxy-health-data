import { FieldPath, FieldValue, Timestamp, type DocumentData, type WriteBatch } from 'firebase-admin/firestore'
import { db } from './firebase'
import type {
  ActivitySummaryInput,
  DailyStatInput,
  HourlyStatInput,
  SampleInput,
  SyncBody,
  SyncLogInput,
  WorkoutInput,
} from './schemas'
import { catalog } from './catalog'
import { computeBattery, groupSleep, type BatteryInputs } from './battery'
import { heartRateZones } from './zones'
import { loadWindows } from './load'
import {
  PlanRejected,
  outcomeFor,
  validateDay,
  wentHarder,
  type DayActual,
  type PlanDay,
} from './plans'
import {
  aggregateWindow,
  usesRawWindow,
  defaults as retentionDefaults,
  sampleWindow,
  settingsFrom,
  type RetentionSettings,
} from './retention'
import { computeReadiness, shouldLockReadiness } from './readiness'
import type { ReadinessInputs } from './readiness'

// Firestore layout
//   users/{uid}                                  profile: timeZone, lastSyncAt
//   users/{uid}/metrics/{type}                   one doc per HealthKit metric (kind, unit, lastSyncAt)
//   users/{uid}/metrics/{type}/samples/{uuid}    raw HealthKit samples
//   users/{uid}/workouts/{uuid}                  HKWorkout (Apple Fitness / Watch workouts)
//   users/{uid}/daily/{yyyy-MM-dd}               per-day aggregates (metrics.*) + activity rings (activity)

const BATCH_LIMIT = 450
/** Documents read per page when stamping expiry, so memory does not track collection size. */
const RETENTION_PAGE_SIZE = 1000
/** Work budget per request; the caller resumes from the returned cursor. */
const PAGE_BUDGET_MS = 90_000

const userRef = (uid: string) => db.collection('users').doc(uid)
const metricsCol = (uid: string) => userRef(uid).collection('metrics')
const samplesCol = (uid: string, type: string) => metricsCol(uid).doc(type).collection('samples')
const workoutsCol = (uid: string) => userRef(uid).collection('workouts')
const dailyCol = (uid: string) => userRef(uid).collection('daily')
const hourlyCol = (uid: string) => userRef(uid).collection('hourly')
const syncsCol = (uid: string) => userRef(uid).collection('syncs')

type Op = (batch: WriteBatch) => void

/**
 * Commits in parallel rather than one batch at a time. A 12 km run uploads ~12,000 documents,
 * which is 28 batches; waiting for each round trip in turn was most of a 52-second sync.
 * Concurrency is bounded so a large upload cannot swamp the instance.
 */
const COMMIT_CONCURRENCY = 6

async function commit(ops: Op[]) {
  const batches: Op[][] = []
  for (let i = 0; i < ops.length; i += BATCH_LIMIT) batches.push(ops.slice(i, i + BATCH_LIMIT))

  for (let i = 0; i < batches.length; i += COMMIT_CONCURRENCY) {
    await Promise.all(
      batches.slice(i, i + COMMIT_CONCURRENCY).map((group) => {
        const batch = db.batch()
        for (const op of group) op(batch)
        return batch.commit()
      }),
    )
  }
}

export class BadRequest extends Error {}

function toTimestamp(iso: string): Timestamp {
  const date = new Date(iso)
  if (Number.isNaN(date.getTime())) throw new BadRequest(`invalid date: ${iso}`)
  return Timestamp.fromDate(date)
}

// ---------- writes ----------

// Expiry is measured from the sample's own date, so "one year" means a year of history rather
// than a year from upload. A Firestore TTL policy on the `expiresAt` field does the deleting;
// nothing here runs on a schedule.
//
// High-frequency metrics (hundreds of samples a day) only keep a short raw window — the hourly
// and daily aggregates carry the long view. Samples recorded during a workout are exempt, so a
// run stays reviewable for as long as the workout itself.
export function sampleExpiry(s: SampleInput, retention: RetentionSettings): Timestamp {
  const window = sampleWindow(s.type, s.context === 'workout', retention)
  return Timestamp.fromMillis(new Date(s.startDate).getTime() + window)
}

/** Aggregates, workouts and the day's computed documents all follow the training window. */
const retentionExpiry = (retention: RetentionSettings, from: Date) =>
  Timestamp.fromMillis(from.getTime() + aggregateWindow(retention))

function sampleDoc(s: SampleInput, retention: RetentionSettings): DocumentData {
  return {
    expiresAt: sampleExpiry(s, retention),
    context: s.context,
    kind: s.kind,
    value: s.value,
    unit: s.unit,
    valueLabel: s.valueLabel,
    startDate: toTimestamp(s.startDate),
    endDate: toTimestamp(s.endDate),
    sourceName: s.sourceName,
    sourceBundleId: s.sourceBundleId,
    device: s.device,
    metadata: s.metadata,
  }
}

function workoutDoc(w: WorkoutInput, retention: RetentionSettings): DocumentData {
  const { id, startDate, endDate, ...rest } = w
  return {
    ...rest,
    startDate: toTimestamp(startDate),
    endDate: toTimestamp(endDate),
    expiresAt: retentionExpiry(retention, new Date(startDate)),
  }
}

// One document per day holding every metric's 24 hourly slots: 365 documents a year rather
// than tens of thousands, and a month of intraday shape comes back in a single query.
export function hourlyDocs(stats: HourlyStatInput[]): Map<string, DocumentData> {
  const days = new Map<string, DocumentData>()
  for (const { date, hour, type, ...values } of stats) {
    let doc = days.get(date)
    if (!doc) days.set(date, (doc = { date, metrics: {} }))
    doc.metrics[type] ??= {}
    doc.metrics[type][hour] = values
  }
  for (const doc of days.values()) {
    if (!Object.keys(doc.metrics).length) delete doc.metrics
  }
  return days
}

export function dailyDocs(stats: DailyStatInput[], rings: ActivitySummaryInput[]): Map<string, DocumentData> {
  const days = new Map<string, DocumentData>()
  const day = (date: string) => {
    let doc = days.get(date)
    if (!doc) days.set(date, (doc = { date, metrics: {} }))
    return doc
  }
  for (const { date, type, ...values } of stats) day(date).metrics[type] = values
  for (const { date, ...activity } of rings) day(date).activity = activity
  // A merge writes each leaf of a nested map on its own, but an empty map has no leaves, so
  // it is written as a value and replaces whatever was stored. A sync that carries rings for a
  // day without new statistics — the usual case, since statistics are only recomputed for
  // metrics that changed — would otherwise erase that day's metrics.
  for (const doc of days.values()) {
    if (!Object.keys(doc.metrics).length) delete doc.metrics
  }
  return days
}

/**
 * Retention per group, filled in from the defaults. A profile saved before groups existed keeps
 * its single choice for every group measured in years.
 */
export async function getRetention(uid: string): Promise<RetentionSettings> {
  const snap = await userRef(uid).get()
  const legacy = snap.get('retentionYears')
  return settingsFrom(snap.get('retention'), typeof legacy === 'number' ? legacy : undefined)
}

export async function setRetention(uid: string, changes: Partial<RetentionSettings>) {
  const current = await getRetention(uid)
  const next = { ...current, ...changes }
  await userRef(uid).set({ retention: next }, { merge: true })
  return next
}

export async function ingest(uid: string, body: SyncBody) {
  const now = FieldValue.serverTimestamp()
  const retention = await getRetention(uid)
  const ops: Op[] = []
  // Per type: the newest sample and a count per recording source, both denormalised onto the
  // metric document below so reads never fan out one query per metric.
  const touchedMetrics = new Map<
    string,
    { kind: string; unit?: string; newest?: SampleInput; oldest?: string; count: number; sources: Map<string, number> }
  >()

  for (const s of body.samples ?? []) {
    const doc = sampleDoc(s, retention)
    ops.push((b) => b.set(samplesCol(uid, s.type).doc(s.id), doc))
    const entry = touchedMetrics.get(s.type) ?? {
      kind: s.kind,
      unit: s.unit,
      count: 0,
      sources: new Map<string, number>(),
    }
    entry.kind = s.kind
    entry.unit = s.unit ?? entry.unit
    if (!entry.newest || s.startDate > entry.newest.startDate) entry.newest = s
    if (!entry.oldest || s.startDate < entry.oldest) entry.oldest = s.startDate
    entry.count += 1
    const source = s.sourceName ?? 'unknown'
    entry.sources.set(source, (entry.sources.get(source) ?? 0) + 1)
    touchedMetrics.set(s.type, entry)
  }
  for (const { type, ids } of body.deletedSamples ?? []) {
    for (const id of ids) ops.push((b) => b.delete(samplesCol(uid, type).doc(id)))
  }
  // `firstAt` may only move backwards — a backfill delivers older samples than anything stored,
  // while a routine sync must not push it forward. That needs the current values, so the metric
  // documents are read once up front.
  const storedFirstAt = new Map<string, Timestamp>()
  if (touchedMetrics.size) {
    const existing = await metricsCol(uid).get()
    for (const doc of existing.docs) {
      const at = doc.get('firstAt')
      if (at instanceof Timestamp) storedFirstAt.set(doc.id, at)
    }
  }

  for (const [type, { kind, unit, newest, oldest, count, sources }] of touchedMetrics) {
    const doc: DocumentData = { type, kind, unit, lastSyncAt: now, sampleCount: FieldValue.increment(count) }
    if (oldest) {
      const candidate = Timestamp.fromDate(new Date(oldest))
      const stored = storedFirstAt.get(type)
      if (!stored || candidate.toMillis() < stored.toMillis()) doc.firstAt = candidate
    }
    if (newest) {
      // Nested maps, not dotted keys: `set` with merge treats a dotted key as a literal field
      // name, while a nested map merges field by field and keeps increments working.
      doc.latest = {
        id: newest.id,
        value: newest.value,
        unit: newest.unit,
        valueLabel: newest.valueLabel,
        startDate: toTimestamp(newest.startDate),
        sourceName: newest.sourceName,
      }
    }
    // Same trap as the daily documents: an empty map is written as a value and would replace
    // the running per-source counts. It cannot be empty today — a metric is only in this list
    // because a sample carried it — but the guard costs nothing and the failure is silent.
    if (sources.size) {
      doc.sources = Object.fromEntries([...sources].map(([source, count]) => [source, FieldValue.increment(count)]))
    }
    ops.push((b) => b.set(metricsCol(uid).doc(type), doc, { merge: true }))
  }


  for (const w of body.workouts ?? []) {
    const doc = workoutDoc(w, retention)
    ops.push((b) => b.set(workoutsCol(uid).doc(w.id), doc))
  }
  for (const id of body.deletedWorkoutIds ?? []) ops.push((b) => b.delete(workoutsCol(uid).doc(id)))

  const days = dailyDocs(body.dailyStats ?? [], body.activitySummaries ?? [])
  for (const [date, doc] of days) {
    const expiresAt = retentionExpiry(retention, new Date(`${date}T00:00:00Z`))
    ops.push((b) => b.set(dailyCol(uid).doc(date), { ...doc, expiresAt, updatedAt: now }, { merge: true }))
  }

  const hours = hourlyDocs(body.hourlyStats ?? [])
  for (const [date, doc] of hours) {
    const expiresAt = retentionExpiry(retention, new Date(`${date}T00:00:00Z`))
    ops.push((b) => b.set(hourlyCol(uid).doc(date), { ...doc, expiresAt, updatedAt: now }, { merge: true }))
  }

  ops.push((b) => b.set(userRef(uid), { timeZone: body.timeZone, ...body.profile, lastSyncAt: now }, { merge: true }))
  await commit(ops)

  return {
    samples: body.samples?.length ?? 0,
    deletedSamples: (body.deletedSamples ?? []).reduce((n, d) => n + d.ids.length, 0),
    workouts: body.workouts?.length ?? 0,
    deletedWorkouts: body.deletedWorkoutIds?.length ?? 0,
    days: days.size,
    hours: hours.size,
  }
}

// ---------- sync history ----------

/** Keeps the log on the server so it survives a reinstall and the MCP tools can read it. */
export async function recordSync(uid: string, entry: SyncLogInput) {
  const startedAt = toTimestamp(entry.startedAt)
  await syncsCol(uid).doc(entry.startedAt).set({
    ...entry,
    // A real timestamp field to sort on: ordering by document id descending is a key scan,
    // which Firestore rejects, and `limitToLast` compiles down to exactly that.
    startedAtTime: startedAt,
    expiresAt: Timestamp.fromMillis(Date.now() + 90 * 86_400_000),
    recordedAt: FieldValue.serverTimestamp(),
  })
}

export async function listSyncs(uid: string, limit = 50) {
  const snap = await syncsCol(uid).orderBy('startedAtTime', 'desc').limit(limit).get()
  return snap.docs.map((d) => {
    const { startedAtTime, ...rest } = plain(d.data())
    return rest
  })
}

// ---------- hourly reads ----------

export async function queryHourly(uid: string, fromDate: string, toDate: string, metrics?: string[]) {
  const snap = await hourlyCol(uid)
    .where(FieldPath.documentId(), '>=', fromDate)
    .where(FieldPath.documentId(), '<=', toDate)
    .orderBy(FieldPath.documentId(), 'asc')
    .get()
  return snap.docs.map((d) => {
    const day = plain(d.data())
    if (metrics?.length && day.metrics) {
      day.metrics = Object.fromEntries(Object.entries(day.metrics).filter(([k]) => metrics.includes(k)))
    }
    return day
  })
}

// ---------- training readiness ----------

/**
 * Gathers the inputs for a readiness score from the daily aggregates and last night's sleep.
 * Baselines are the user's own mean over the window, so "normal" means normal for them.
 */
export async function collectReadinessInputs(uid: string, baselineDays = 90): Promise<ReadinessInputs> {
  const timeZone = String((await getProfile(uid)).timeZone ?? 'UTC')
  const today = new Date()
  const key = (date: Date) => new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' }).format(date)
  const from = key(new Date(today.getTime() - baselineDays * 86_400_000))
  const series = await dailySeries(uid, from, key(today), [
    'heartRateVariabilitySDNN',
    'restingHeartRate',
    'appleExerciseTime',
  ])

  // Sleeping HRV is the comparable figure, but it is only used once there are enough nights to
  // build a baseline from — and then for both sides of the comparison, since a sleeping reading
  // against a whole-day baseline would be a different number against a different yardstick.
  const sleepHrv = await sleepHrvByNight(
    uid,
    { from: new Date(today.getTime() - baselineDays * 86_400_000), to: today },
    timeZone,
  )
  const sleepHrvNights = [...sleepHrv.entries()].sort(([a], [b]) => a.localeCompare(b))
  const useSleepHrv = sleepHrvNights.length >= SLEEP_HRV_MINIMUM_NIGHTS

  const latestAndBaseline = (type: string) => {
    const values = (series[type] ?? []).map((p) => p.avg ?? p.sum).filter((v): v is number => typeof v === 'number')
    if (values.length < 2) return undefined
    return { latest: values[values.length - 1]!, baseline: values.reduce((a, b) => a + b, 0) / values.length }
  }

  // Keyed by date so a day with no exercise counts as zero rather than dropping out of the
  // average — the series only carries days that have a reading.
  const exerciseByDate = new Map(
    (series.appleExerciseTime ?? [])
      .filter((p) => typeof p.date === 'string')
      .map((p) => [String(p.date), Number(p.sum ?? 0)]),
  )
  const load = loadWindows(exerciseByDate, key(today))

  // Last night only: readiness is about today. querySleep returns newest first, and the oldest
  // entry in the window is usually a night cut in half by the window's start — taking it gave a
  // 34-minute "night" and a wrecked score.
  const nights = await querySleep(
    uid,
    // Reach back far enough that last night's bedtime is inside the window, like get_sleep does.
    { from: new Date(today.getTime() - 2 * 86_400_000 - 18 * 3_600_000), to: today },
    timeZone,
  )
  const lastNight = nights
    .filter((n): n is typeof n & { date: string } => typeof n.date === 'string')
    .sort((a, b) => b.date.localeCompare(a.date))[0]
  const sleepMinutes = typeof lastNight?.asleepMinutes === 'number' ? lastNight.asleepMinutes : undefined
  // Only the explicit stage counts. Falling back to the sleep window produced a figure a few
  // minutes above time asleep and called it time in bed, which says nothing and implies a lot.
  const stages = (lastNight?.stagesMinutes ?? {}) as Record<string, number>
  const inBedMinutes = typeof stages.inBed === 'number' ? stages.inBed : undefined
  const baseline = await sleepBaseline(uid)

  const hrvValues = sleepHrvNights.map(([, v]) => v.value)
  const hrv = useSleepHrv
    ? {
        latest: median(hrvValues.slice(-SLEEP_HRV_RECENT_NIGHTS)),
        baseline: median(hrvValues),
      }
    : latestAndBaseline('heartRateVariabilitySDNN')

  return {
    hrv,
    loadWindows: load ? { acuteDays: load.acuteDays, chronicDays: load.chronicDays, historyDays: load.historyDays } : undefined,
    hrvSource: useSleepHrv ? ('sleep' as const) : ('daily' as const),
    hrvNights: sleepHrvNights.length,
    hrvRecentNights: useSleepHrv ? Math.min(SLEEP_HRV_RECENT_NIGHTS, sleepHrvNights.length) : undefined,
    hrvLastNight: useSleepHrv ? sleepHrvNights[sleepHrvNights.length - 1]?.[1].value : undefined,
    restingHeartRate: latestAndBaseline('restingHeartRate'),
    sleepMinutes,
    inBedMinutes,
    usualSleepMinutes: baseline?.asleepMinutes,
    load,
    wakeTime: lastNight?.wakeTime ? String(lastNight.wakeTime) : undefined,
  }
}

const readinessCol = (uid: string) => userRef(uid).collection('readiness')
const baselinesCol = (uid: string) => userRef(uid).collection('baselines')

/** Nights the sleep baseline is taken over. */
const SLEEP_BASELINE_DAYS = 90
/** Below this, "normal for you" is not a thing yet. */
const SLEEP_BASELINE_MINIMUM_NIGHTS = 14

export interface SleepBaseline {
  nights: number
  asleepMinutes: number
  stagesMinutes: Record<string, number>
  from: string
  to: string
  computedAt: string
}

/**
 * What a normal night looks like for this user, as medians rather than means — one twelve-hour
 * catch-up should not move the figure a coach compares tonight against.
 *
 * Ninety nights of stage samples is a few thousand documents, so the answer is computed once a
 * local day and then read back. It is context, never a score: the sleep factor still measures
 * against a target, because "normal for you" being six and a half hours is the problem, not the
 * yardstick.
 */
export async function sleepBaseline(uid: string): Promise<SleepBaseline | undefined> {
  const timeZone = String((await getProfile(uid)).timeZone ?? 'UTC')
  const now = new Date()
  const today = new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' }).format(now)
  const ref = baselinesCol(uid).doc('sleep')

  const stored = await ref.get()
  if (stored.exists && stored.get('to') === today) return plain(stored.data()!) as unknown as SleepBaseline

  const from = new Date(now.getTime() - SLEEP_BASELINE_DAYS * 86_400_000)
  const nights = (await querySleep(uid, { from, to: now }, timeZone)).filter((n) => n.asleepMinutes > 0)
  if (nights.length < SLEEP_BASELINE_MINIMUM_NIGHTS) return undefined

  const stageKeys = new Set(nights.flatMap((n) => Object.keys(n.stagesMinutes)))
  const baseline: SleepBaseline = {
    nights: nights.length,
    asleepMinutes: Math.round(medianOf(nights.map((n) => n.asleepMinutes))),
    stagesMinutes: Object.fromEntries(
      [...stageKeys].map((key) => [
        key,
        Math.round(medianOf(nights.map((n) => n.stagesMinutes[key] ?? 0).filter((v) => v > 0))),
      ]),
    ),
    from: new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' }).format(from),
    to: today,
    computedAt: now.toISOString(),
  }
  await ref.set(baseline, { merge: true })
  return baseline
}

/**
 * Heart-rate zones for this user, cached for the day.
 *
 * It costs a year of workouts and a month of resting pulse to work out, and the answer changes
 * about as often as a personal best — so it is computed once a local day and read back, the
 * same way the sleep baseline is.
 */
export async function heartRateZonesFor(uid: string) {
  const profile = await getProfile(uid)
  const timeZone = String(profile.timeZone ?? 'UTC')
  const now = new Date()
  const today = new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' }).format(now)
  const ref = baselinesCol(uid).doc('heartRateZones')

  const stored = await ref.get()
  if (stored.exists && stored.get('to') === today) return plain(stored.data()!)

  const from = new Date(now.getTime() - 365 * 86_400_000)
  const [workouts, series] = await Promise.all([
    queryWorkouts(uid, { from, to: now }, 400, undefined, timeZone),
    dailySeries(uid, new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' })
      .format(new Date(now.getTime() - catalog.heartRate.restingMedianDays * 86_400_000)), today, ['restingHeartRate']),
  ])

  const observed = workouts
    .map((w) => ({ value: w.maxHeartRate as number | undefined, at: String(w.startLocal ?? w.startDate ?? '').slice(0, 10) }))
    .filter((w): w is { value: number; at: string } => typeof w.value === 'number')
    .map((w) => ({ value: Math.round(w.value), at: w.at }))
  const resting = (series.restingHeartRate ?? [])
    .map((p) => p.avg)
    .filter((v): v is number => typeof v === 'number')

  const zones = {
    ...heartRateZones({
      observed,
      restingHeartRate: resting.length ? Math.round(medianOf(resting)) : undefined,
      age: ageFromDateOfBirth(profile.dateOfBirth),
    }),
    to: today,
    computedAt: now.toISOString(),
  }
  await ref.set(zones, { merge: true })
  return plain(zones as DocumentData)
}

/** Whole years, from a stored ISO date of birth. */
function ageFromDateOfBirth(dateOfBirth: unknown) {
  if (typeof dateOfBirth !== 'string') return undefined
  const born = new Date(dateOfBirth)
  if (Number.isNaN(born.getTime())) return undefined
  const years = (Date.now() - born.getTime()) / (365.25 * 86_400_000)
  return years > 0 && years < 120 ? Math.floor(years) : undefined
}

function medianOf(values: number[]) {
  if (!values.length) return 0
  const sorted = [...values].sort((a, b) => a - b)
  const middle = Math.floor(sorted.length / 2)
  return sorted.length % 2 ? sorted[middle]! : (sorted[middle - 1]! + sorted[middle]!) / 2
}

/**
 * The day's readiness, computed once and then served from storage. The app and the MCP tools
 * read the same document, so they cannot quote different numbers, and reopening the app costs
 * one document read instead of ninety days of statistics.
 */
export async function getReadiness(uid: string) {
  const timeZone = String((await getProfile(uid)).timeZone ?? 'UTC')
  const now = new Date()
  const date = new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' }).format(now)
  const localHour = Number(new Intl.DateTimeFormat('en-GB', { timeZone, hour: '2-digit', hour12: false }).format(now))
  const ref = readinessCol(uid).doc(date)

  const stored = await ref.get()
  if (stored.exists && stored.get('locked') === true) return plain(stored.data()!)

  const inputs = await collectReadinessInputs(uid)
  const result = computeReadiness(inputs)
  const locked = shouldLockReadiness(result.missing, localHour)
  const doc = {
    ...result,
    date,
    wakeTime: inputs.wakeTime,
    computedAt: now.toISOString(),
    locked,
    expiresAt: retentionExpiry(await getRetention(uid), new Date(`${date}T00:00:00Z`)),
  }
  await ref.set(doc, { merge: true })
  return plain(doc as DocumentData)
}

/**
 * Sleep split into sessions rather than nights: samples closer together than an hour belong to
 * the same stretch of sleep. `querySleep` groups by the local date a sample ends on, which puts
 * an afternoon nap into the same bucket as the night before it — fine for a sleep report, wrong
 * for a battery that charges per hour asleep.
 */
export async function sleepSessions(uid: string, range: Range, limit = 5000) {
  // The cap matters: samples come back newest first, so a window wider than the cap would
  // quietly lose its oldest nights — which is exactly the end a baseline needs.
  const samples = await querySamples(uid, 'sleepAnalysis', range, limit)
  const asleep = samples
    .filter((s) => ASLEEP.has(String(s.valueLabel ?? s.value)))
    .map((s) => ({ start: new Date(String(s.startDate)).getTime(), end: new Date(String(s.endDate)).getTime() }))
    .filter((s) => Number.isFinite(s.start) && Number.isFinite(s.end))
    .sort((a, b) => a.start - b.start)

  const GAP_MS = 60 * 60_000
  const sessions: { start: number; end: number; asleepMinutes: number }[] = []
  for (const sample of asleep) {
    const current = sessions[sessions.length - 1]
    // Overlapping samples are the same minutes recorded by two sources, so time is counted from
    // the union rather than by adding the pieces up.
    if (current && sample.start - current.end <= GAP_MS) {
      if (sample.end > current.end) {
        current.asleepMinutes += (sample.end - Math.max(sample.start, current.end)) / 60_000
        current.end = sample.end
      }
      continue
    }
    sessions.push({ start: sample.start, end: sample.end, asleepMinutes: (sample.end - sample.start) / 60_000 })
  }
  return sessions.map((s) => ({ ...s, asleepMinutes: Math.round(s.asleepMinutes) }))
}

/** Sleep this long counts as a night even when it ends outside the morning. */
const NIGHT_MINUTES = 150

/**
 * HRV measured while actually asleep, per night.
 *
 * Apple publishes one daily average that mixes readings taken during a run, during a stressful
 * meeting and during sleep, which is why the same person's daily figure swings between 28 and
 * 115 ms. Only the sleeping readings are comparable night to night, so they are picked out here
 * and keyed by the morning the night ended on.
 *
 * The median, not the mean: the watch manages about three readings a night and they scatter
 * wildly — one real night reads 53, 148 and 219 ms — so a single spike would otherwise set the
 * whole night.
 */
export async function sleepHrvByNight(uid: string, range: Range, timeZone: string) {
  const dayOf = new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' })
  const [sessions, samples] = await Promise.all([
    sleepSessions(uid, range, BASELINE_SAMPLE_LIMIT),
    querySamples(uid, 'heartRateVariabilitySDNN', range, BASELINE_SAMPLE_LIMIT),
  ])

  const readings = new Map<string, number[]>()
  for (const sample of samples) {
    const at = new Date(String(sample.startDate)).getTime()
    const value = typeof sample.value === 'number' ? sample.value : undefined
    if (value === undefined || !Number.isFinite(at)) continue
    const session = sessions.find((s) => at >= s.start && at <= s.end)
    if (!session) continue
    const date = dayOf.format(new Date(session.end))
    readings.set(date, [...(readings.get(date) ?? []), value])
  }

  return new Map(
    [...readings].map(([date, values]) => [date, { value: median(values), count: values.length }]),
  )
}

function median(values: number[]) {
  const sorted = [...values].sort((a, b) => a - b)
  const middle = Math.floor(sorted.length / 2)
  return sorted.length % 2 ? sorted[middle]! : (sorted[middle - 1]! + sorted[middle]!) / 2
}

/** Ninety nights of stage samples runs to a few thousand documents; the cap is a ceiling that
 *  keeps a wide window from silently losing its oldest end, not a target. */
const BASELINE_SAMPLE_LIMIT = 20_000

/** Nights of sleeping HRV needed before it is trusted over Apple's daily average. */
const SLEEP_HRV_MINIMUM_NIGHTS = 14

/**
 * Nights the current figure is taken over. One night is not usable: with three readings a night
 * the figure moves 38 ms from one morning to the next, which is most of the range it lives in.
 * Three nights cuts that to 13 and still answers "how is this week going" rather than "how is
 * this month going".
 */
const SLEEP_HRV_RECENT_NIGHTS = 3

/** Days of history simulated so the level carried into this morning is itself earned. */
const BATTERY_HISTORY_DAYS = catalog.battery.historyDays
/** Nights looked at when a missing night has to be stood in for. */
const BATTERY_MEDIAN_NIGHTS = 14
/** Sleep that ends before this local hour belongs to the night; later is a nap. A night broken
 *  by an hour awake arrives as two sessions, and counting only the longer one would throw away
 *  half the sleep — or worse, charge the larger half at the capped nap rate. */
const NIGHT_ENDS_BEFORE_HOUR = 12

/**
 * Inputs for the body battery: one entry per day, oldest first, each with the night that ended
 * that morning, any naps, and the hourly energy and heart rate while awake. The level is carried
 * from one day to the next, so the chain has to be built rather than today alone.
 */
export async function collectBatteryInputs(uid: string): Promise<BatteryInputs> {
  const timeZone = String((await getProfile(uid)).timeZone ?? 'UTC')
  const now = new Date()
  const dayFormat = new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' })
  const hourFormat = new Intl.DateTimeFormat('en-GB', { timeZone, hour: '2-digit', hour12: false })
  const key = (date: Date) => dayFormat.format(date)
  const hourOf = (date: Date) => Number(hourFormat.format(date))
  const today = key(now)

  const historyFrom = key(new Date(now.getTime() - BATTERY_HISTORY_DAYS * 86_400_000))
  const [hourly, series, sessions] = await Promise.all([
    queryHourly(uid, historyFrom, today, ['activeEnergyBurned', 'heartRate']),
    dailySeries(uid, key(new Date(now.getTime() - 30 * 86_400_000)), today, ['restingHeartRate']),
    sleepSessions(uid, { from: new Date(now.getTime() - (BATTERY_MEDIAN_NIGHTS + 1) * 86_400_000), to: now }),
  ])

  const restingSeries = (series.restingHeartRate ?? []).map((p) => p.avg).filter((v): v is number => typeof v === 'number')
  const restingHeartRate = restingSeries.length ? restingSeries[restingSeries.length - 1] : undefined

  const { nights, wokeAt, naps } = groupSleep(
    sessions.map((session) => ({
      date: key(new Date(session.end)),
      hour: hourOf(new Date(session.end)),
      asleepMinutes: session.asleepMinutes,
    })),
    NIGHT_ENDS_BEFORE_HOUR,
    NIGHT_MINUTES,
  )

  // A night the watch did not record is stood in for by the median of the nights it did, so the
  // morning after a charging session is not reported as a night of no sleep at all.
  const recent = [...nights.values()].sort((a, b) => a - b)
  const medianNight = recent.length ? recent[Math.floor(recent.length / 2)] : undefined

  const byDate = new Map(hourly.map((day) => [String((day as { date?: string }).date), day]))
  const hoursOf = (date: string, from: number) => {
    const metrics = ((byDate.get(date) as { metrics?: unknown } | undefined)?.metrics ?? {}) as Record<
      string,
      Record<string, { sum?: number; avg?: number }>
    >
    const hours: { hour: number; activeEnergyKcal?: number; heartRate?: number }[] = []
    const last = date === today ? hourOf(now) : 23
    for (let hour = from; hour <= last; hour += 1) {
      const energy = metrics.activeEnergyBurned?.[hour]?.sum
      const heartRate = metrics.heartRate?.[hour]?.avg
      if (energy === undefined && heartRate === undefined) continue
      hours.push({ hour, activeEnergyKcal: energy, heartRate })
    }
    return hours
  }

  const days: BatteryInputs['days'] = []
  for (let back = BATTERY_HISTORY_DAYS; back >= 0; back -= 1) {
    const date = key(new Date(now.getTime() - back * 86_400_000))
    const measured = nights.get(date)
    const asleepMinutes = measured ?? medianNight
    // Waking hour comes from the night that ended that morning; without one the day counts whole.
    const wakeHour = wokeAt.get(date) ?? 0
    days.push({
      date,
      asleepMinutes,
      sleepEstimated: measured === undefined && asleepMinutes !== undefined,
      naps: naps.get(date) ?? [],
      hours: hoursOf(date, wakeHour),
      restingHeartRate,
    })
  }

  return { days, hourNow: hourOf(now) }
}

const plansCol = (uid: string) => userRef(uid).collection('plans')

/**
 * Writes plan days, one at a time, so a batch reports per day rather than failing as a block —
 * a coach writing a week should not lose Tuesday because Monday has already been run.
 */
export async function setPlans(uid: string, days: unknown[], client?: string) {
  const timeZone = String((await getProfile(uid)).timeZone ?? 'UTC')
  const today = new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' })
    .format(new Date())
  const retention = await getRetention(uid)

  // Which days already carry a workout, since today closes once one does.
  const dates = days.map((d) => String((d as { date?: unknown })?.date ?? ''))
  const workoutDates = new Set(await datesWithWorkouts(uid, dates.filter(Boolean), timeZone))

  const written: PlanDay[] = []
  const refused: { date: string; reason: string }[] = []
  const ops: Op[] = []

  for (const day of days) {
    const date = String((day as { date?: unknown })?.date ?? '')
    try {
      const plan = validateDay(day, today, workoutDates.has(date))
      const ref = plansCol(uid).doc(plan.date)
      const existing = await ref.get()
      ops.push((b) =>
        b.set(
          ref,
          {
            ...plan,
            source: 'mcp',
            client: client ?? null,
            revision: ((existing.get('revision') as number | undefined) ?? 0) + 1,
            createdAt: existing.get('createdAt') ?? FieldValue.serverTimestamp(),
            updatedAt: FieldValue.serverTimestamp(),
            expiresAt: retentionExpiry(retention, new Date(`${plan.date}T00:00:00Z`)),
          },
          { merge: true },
        ),
      )
      written.push(plan)
    } catch (error) {
      refused.push({ date, reason: error instanceof PlanRejected ? error.message : 'ข้อมูลแผนไม่ถูกต้อง' })
    }
  }
  if (ops.length) await commit(ops)
  return { written, refused, today }
}

/** Local dates on which a workout is already recorded. */
async function datesWithWorkouts(uid: string, dates: string[], timeZone: string) {
  if (!dates.length) return []
  const sorted = [...dates].sort()
  const from = new Date(`${sorted[0]}T00:00:00Z`)
  const to = new Date(new Date(`${sorted[sorted.length - 1]}T00:00:00Z`).getTime() + 2 * 86_400_000)
  const workouts = await queryWorkouts(uid, { from, to }, 200)
  const dayOf = new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' })
  return workouts.map((w) => dayOf.format(new Date(String(w.startDate))))
}

/**
 * The calendar: every day in the range with its plan, what was actually done, and what became
 * of the two. The outcome is decided here rather than in the reader, so the app and the tools
 * cannot draw different conclusions from the same day.
 */
export async function getPlanRange(uid: string, from: string, to: string) {
  const timeZone = String((await getProfile(uid)).timeZone ?? 'UTC')
  const dayOf = new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' })
  const today = dayOf.format(new Date())

  const [plans, workouts, zones] = await Promise.all([
    plansCol(uid).where(FieldPath.documentId(), '>=', from).where(FieldPath.documentId(), '<=', to).get(),
    queryWorkouts(
      uid,
      { from: new Date(`${from}T00:00:00Z`), to: new Date(new Date(`${to}T00:00:00Z`).getTime() + 2 * 86_400_000) },
      300,
      undefined,
      timeZone,
    ),
    heartRateZonesFor(uid).catch(() => undefined),
  ])

  const planByDate = new Map(plans.docs.map((d) => [d.id, plain(d.data()) as unknown as PlanDay]))
  const actualByDate = new Map<string, DocumentData[]>()
  for (const workout of workouts) {
    const date = dayOf.format(new Date(String(workout.startDate)))
    actualByDate.set(date, [...(actualByDate.get(date) ?? []), workout])
  }

  const days: DocumentData[] = []
  for (let date = from; date <= to; date = shiftDay(date, 1)) {
    const plan = planByDate.get(date)
    const actuals = actualByDate.get(date) ?? []
    const summarised: DayActual[] = actuals.map((w) => ({
      activityTypeName: String(w.activityTypeName ?? ''),
      avgHeartRate: typeof w.avgHeartRate === 'number' ? w.avgHeartRate : undefined,
      paceSecPerKm:
        typeof w.distanceM === 'number' && w.distanceM > 0 && typeof w.durationSec === 'number'
          ? Math.round(w.durationSec / (w.distanceM / 1000))
          : undefined,
    }))
    const { outcome } = outcomeFor({ date, today, plan, actuals: summarised })
    const ceiling = zoneCeilingFor(zones, plan)
    days.push({
      date,
      outcome,
      harder: wentHarder(plan, summarised, ceiling),
      plan: plan ?? null,
      actual: actuals.map((w) => ({
        id: w.id,
        activityTypeName: w.activityTypeName,
        startLocal: w.startLocal,
        distanceKm: typeof w.distanceM === 'number' ? Number((w.distanceM / 1000).toFixed(2)) : undefined,
        minutes: typeof w.durationSec === 'number' ? Math.round(w.durationSec / 60) : undefined,
        avgHeartRate: w.avgHeartRate,
        maxHeartRate: w.maxHeartRate,
      })),
    })
  }
  return { from, to, today, timeZone, days }
}

/** Top of the zone a session was written for, so "harder than planned" has a number to test. */
function zoneCeilingFor(zones: DocumentData | undefined, plan: PlanDay | undefined) {
  const target = plan?.steps?.reduce((max, s) => Math.max(max, s.zone ?? 0), 0)
  if (!target || !zones) return undefined
  const list = (zones.zones ?? []) as { zone: number; to: number }[]
  return list.find((z) => z.zone === target)?.to
}

const shiftDay = (date: string, days: number) =>
  new Date(new Date(`${date}T00:00:00Z`).getTime() + days * 86_400_000).toISOString().slice(0, 10)

// ---------- retention backfill ----------

/**
 * Stamps `expiresAt` on documents written before retention existed, using the same rules as
 * ingest. Runs one scope at a time (a metric type, or daily/hourly/workouts) so each call stays
 * well inside the request timeout; the caller walks the scopes.
 *
 * Samples uploaded before the `context` field existed carry no workout marker, so workout
 * intervals are reconstructed here — otherwise the short window would delete exactly the
 * per-workout heart rate and pace that get_workout_detail depends on.
 */
export async function applyRetention(uid: string, scope: string, dryRun: boolean, after?: string) {
  const started = Date.now()
  const retention = await getRetention(uid)
  let scanned = 0
  let stamped = 0
  // Batched commits rather than a BulkWriter: the same path ingest uses, and a failed write
  // surfaces as a rejected commit instead of an unhandled rejection that kills the instance.
  let ops: Op[] = []

  // Only ever brings an expiry forward. A document that already expires sooner than the rule
  // would set is left alone, so re-running this can never resurrect data.
  const stamp = (ref: FirebaseFirestore.DocumentReference, at: number, window: number, current?: Timestamp) => {
    const target = at + window
    if (current && current.toMillis() <= target) return
    stamped += 1
    if (!dryRun) ops.push((b) => b.set(ref, { expiresAt: Timestamp.fromMillis(target) }, { merge: true }))
  }

  const isDated = scope === 'daily' || scope === 'hourly' || scope === 'workouts'
  const collection = isDated
    ? scope === 'daily'
      ? dailyCol(uid)
      : scope === 'hourly'
        ? hourlyCol(uid)
        : workoutsCol(uid)
    : samplesCol(uid, scope)

  // Workout windows are needed to tell which high-frequency samples survive the short window.
  // Loaded once: there are tens of them, not tens of thousands.
  const rawWindowed = !isDated && usesRawWindow(scope)
  let intervals: { from: number; to: number }[] = []
  if (rawWindowed) {
    const workouts = await workoutsCol(uid).get()
    intervals = workouts.docs.map((d) => ({
      from: (d.get('startDate') as Timestamp).toMillis(),
      to: (d.get('endDate') as Timestamp).toMillis() + catalog.sync.recoveryTailSeconds * 1000,
    }))
  }

  // Paged by document id — an ascending key scan, which Firestore does support — so memory stays
  // flat regardless of collection size. A 32k-document collection used to load in one go and
  // take the container down with it.
  let cursor = after
  let done = false
  while (Date.now() - started < PAGE_BUDGET_MS) {
    let query = collection.orderBy(FieldPath.documentId()).limit(RETENTION_PAGE_SIZE)
    if (cursor) query = query.startAfter(cursor)
    const page = await query.get()
    if (page.empty) {
      done = true
      break
    }

    for (const doc of page.docs) {
      scanned += 1
      // A metric that moved to the short tier after its samples were written still carries the
      // old two-year expiry, so an existing value is re-checked rather than skipped.
      const current = doc.get('expiresAt') as Timestamp | undefined
      const start = doc.get('startDate') as Timestamp | undefined
      const at = isDated && !start ? new Date(`${doc.id}T00:00:00Z`).getTime() : start?.toMillis()
      if (at === undefined || !Number.isFinite(at)) continue
      const inWorkout = doc.get('context') === 'workout' || intervals.some((i) => at >= i.from && at <= i.to)
      const window = isDated
        ? aggregateWindow(retention)
        : sampleWindow(scope, rawWindowed && inWorkout, retention)
      stamp(doc.ref, at, window, current)
    }

    if (ops.length) {
      await commit(ops)
      ops = []
    }
    cursor = page.docs[page.docs.length - 1]!.id
    if (page.size < RETENTION_PAGE_SIZE) {
      done = true
      break
    }
  }

  if (ops.length) await commit(ops)
  // `done: false` means the budget ran out; call again with `after` to carry on.
  return { scope, scanned, stamped, retention, dryRun, done, after: done ? undefined : cursor }
}

// ---------- destructive ----------

/** Deletes every health document for a user, leaving the profile and OAuth state alone. */
export async function deleteAllData(uid: string) {
  const writer = db.bulkWriter()
  for (const col of [metricsCol(uid), workoutsCol(uid), dailyCol(uid), hourlyCol(uid), syncsCol(uid)]) {
    await db.recursiveDelete(col, writer)
  }
  await writer.close()
}

// ---------- reads ----------

// Converts Firestore Timestamps to ISO strings so results are plain JSON.
function plain(data: DocumentData): DocumentData {
  const out: DocumentData = {}
  for (const [key, value] of Object.entries(data)) {
    if (value instanceof Timestamp) out[key] = value.toDate().toISOString()
    else if (value && typeof value === 'object' && !Array.isArray(value)) out[key] = plain(value)
    else out[key] = value
  }
  return out
}

export interface Range {
  from: Date
  to: Date
}

export async function getProfile(uid: string): Promise<DocumentData> {
  const snap = await userRef(uid).get()
  return { uid, ...(snap.exists ? plain(snap.data()!) : {}) }
}

export async function listMetrics(uid: string, types?: string[], withSources = false, withCounts = false) {
  const snap = await metricsCol(uid).get()
  const docs = types?.length ? snap.docs.filter((d) => types.includes(d.id)) : snap.docs
  return Promise.all(
    docs.map(async (doc) => {
      const { latest, sources, ...rest } = plain(doc.data())
      // Docs written before `latest` was denormalised still need the old per-metric query.
      const resolved = latest ?? (await legacyLatest(uid, doc.id))
      // `sampleCount` only counts what has been uploaded since the counter was added, and TTL
      // deletions never decrement it. An aggregation query is exact and costs one read per
      // thousand documents.
      const count = withCounts ? (await samplesCol(uid, doc.id).count().get()).data().count : undefined
      // `firstAt` on the metric document is the oldest sample ever uploaded, and TTL deletions
      // never move it: weight claimed to go back to 2018 while the oldest document held was from
      // 2024. Anyone reading it would plan a trend over years of data that is gone.
      const oldest = withCounts ? await oldestSample(uid, doc.id) : undefined
      // `sampleCount` is a running total that never saw what was written before it existed and
      // does not come down when retention deletes. Where the exact count is available it is the
      // only one reported, so there are not two numbers disagreeing in the same response.
      const { sampleCount, ...withoutCounter } = rest as DocumentData
      const base = withCounts
        ? {
            ...withoutCounter,
            type: doc.id,
            latest: resolved ?? null,
            count,
            firstAt: oldest ?? null,
            firstSyncedAt: (rest as DocumentData).firstAt ?? null,
          }
        : { ...rest, type: doc.id, latest: resolved ?? null }
      if (!withSources) return base
      const counts = sources as Record<string, number> | undefined
      return {
        ...base,
        sources: counts
          ? Object.entries(counts)
              .map(([source, count]) => ({ source, count }))
              .sort((a, b) => b.count - a.count)
          : await metricSources(uid, doc.id),
      }
    }),
  )
}

/** Oldest sample still held, as opposed to the oldest ever uploaded. */
async function oldestSample(uid: string, type: string) {
  const snap = await samplesCol(uid, type).orderBy('startDate').limit(1).get()
  const at = snap.docs[0]?.get('startDate')
  return at instanceof Timestamp ? at.toDate().toISOString() : undefined
}

async function legacyLatest(uid: string, type: string) {
  const snap = await samplesCol(uid, type).orderBy('startDate', 'desc').limit(1).get()
  const doc = snap.docs[0]
  return doc ? { id: doc.id, ...plain(doc.data()) } : null
}

// Which apps and devices report a metric, newest first. A metric with more than one source
// (Watch and a scale app both logging weight, say) can look duplicated in the raw samples.
export async function metricSources(uid: string, type: string, limit = 500) {
  const snap = await samplesCol(uid, type).orderBy('startDate', 'desc').limit(limit).get()
  const seen = new Map<string, { source: string; count: number; latest: string }>()
  for (const doc of snap.docs) {
    const source = String(doc.get('sourceName') ?? 'unknown')
    const at = (doc.get('startDate') as Timestamp | undefined)?.toDate().toISOString() ?? ''
    const entry = seen.get(source)
    if (entry) entry.count += 1
    else seen.set(source, { source, count: 1, latest: at })
  }
  return [...seen.values()].sort((a, b) => b.count - a.count)
}

export async function querySamples(uid: string, type: string, range: Range, limit: number, source?: string) {
  const snap = await samplesCol(uid, type)
    .where('startDate', '>=', Timestamp.fromDate(range.from))
    .where('startDate', '<', Timestamp.fromDate(range.to))
    .orderBy('startDate', 'desc')
    // Filtering by source after the fact keeps this on the existing single-field index.
    .limit(source ? Math.min(limit * 10, 5000) : limit)
    .get()
  const needle = source?.toLowerCase()
  return snap.docs
    .map((d): DocumentData => ({ id: d.id, type, ...plain(d.data()) }))
    .filter((s) => !needle || String(s.sourceName ?? '').toLowerCase().includes(needle))
    .slice(0, limit)
}

// HealthKit hands workout weather over as formatted quantity strings ("78.26 degF", "9000 %").
// Read as-is a model would report 9000% humidity, so they are parsed into plain numbers here —
// on the read path, so workouts synced before this existed are covered too.
function weatherOf(metadata: unknown): DocumentData {
  const meta = (metadata ?? {}) as Record<string, unknown>
  const out: DocumentData = {}

  const temp = String(meta.HKWeatherTemperature ?? '').match(/^(-?[\d.]+)\s*(degF|degC|K)/)
  if (temp) {
    const value = Number(temp[1])
    const celsius = temp[2] === 'degF' ? (value - 32) / 1.8 : temp[2] === 'K' ? value - 273.15 : value
    if (Number.isFinite(celsius)) out.weatherTempC = Number(celsius.toFixed(1))
  }

  // Relative humidity arrives in hundredths of a percent: "9000 %" is 90%.
  const humidity = String(meta.HKWeatherHumidity ?? '').match(/^([\d.]+)\s*%/)
  if (humidity) {
    const percent = Number(humidity[1]) / 100
    if (Number.isFinite(percent)) out.weatherHumidityPercent = Number(percent.toFixed(1))
  }
  return out
}

export async function getWorkout(uid: string, id: string): Promise<DocumentData | null> {
  const doc = await workoutsCol(uid).doc(id).get()
  if (!doc.exists) return null
  const data = plain(doc.data()!)
  return { id: doc.id, ...data, ...weatherOf(data.metadata) }
}

export async function queryWorkouts(uid: string, range: Range, limit: number, activityType?: string, timeZone?: string) {
  // Equality on activityTypeName is served by the automatic single-field index, so an activity
  // filter no longer means reading 1000 docs and throwing most of them away.
  let query = workoutsCol(uid)
    .where('startDate', '>=', Timestamp.fromDate(range.from))
    .where('startDate', '<', Timestamp.fromDate(range.to))
  if (activityType) query = query.where('activityTypeName', '==', activityType)
  const snap = await query.orderBy('startDate', 'desc').limit(limit).get()
  return snap.docs.map((d): DocumentData => {
    const data = plain(d.data())
    return {
      id: d.id,
      ...data,
      // "Was this the morning run or the evening one" is unanswerable from a UTC stamp alone.
      startLocal: timeZone ? localClock(String(data.startDate), timeZone) : undefined,
      ...weatherOf(data.metadata),
    }
  })
}

export async function queryDaily(uid: string, fromDate: string, toDate: string, metrics?: string[]) {
  const snap = await dailyCol(uid)
    .where(FieldPath.documentId(), '>=', fromDate)
    .where(FieldPath.documentId(), '<=', toDate)
    .orderBy(FieldPath.documentId(), 'asc')
    .get()
  return snap.docs.map((d) => {
    const day = plain(d.data())
    if (metrics?.length && day.metrics) {
      day.metrics = Object.fromEntries(Object.entries(day.metrics).filter(([k]) => metrics.includes(k)))
    }
    return day
  })
}

// Reshapes the daily aggregates into one series per metric. These values come from
// HKStatisticsCollectionQuery on the phone, so iPhone/Watch double counting is already resolved.
export async function dailySeries(uid: string, fromDate: string, toDate: string, types: string[]) {
  const days = await queryDaily(uid, fromDate, toDate, types)
  const series: Record<string, DocumentData[]> = {}
  for (const day of days) {
    const metrics = (day.metrics ?? {}) as Record<string, DocumentData>
    for (const [type, values] of Object.entries(metrics)) {
      if (!types.includes(type)) continue
      ;(series[type] ??= []).push({ date: day.date, ...values })
    }
  }
  return series
}

// Most recent daily aggregate per metric. Weight, body fat and other weekly-ish metrics fall
// outside the raw-sample window, so they have no `latest` sample even though the trend is there.
export async function latestDailyValues(uid: string, types?: string[], lookbackDays = 200) {
  // Ascending then reversed: Firestore rejects a descending scan on document ids.
  const from = new Date(Date.now() - lookbackDays * 86_400_000).toISOString().slice(0, 10)
  const snap = await dailyCol(uid)
    .where(FieldPath.documentId(), '>=', from)
    .orderBy(FieldPath.documentId(), 'asc')
    .get()
  const latest: Record<string, DocumentData> = {}
  for (const doc of [...snap.docs].reverse()) {
    const metrics = (doc.get('metrics') ?? {}) as Record<string, DocumentData>
    for (const [type, values] of Object.entries(metrics)) {
      if (types?.length && !types.includes(type)) continue
      if (latest[type]) continue // docs come newest first
      latest[type] = { date: doc.id, ...values }
    }
  }
  return latest
}

const ASLEEP = new Set(['asleepUnspecified', 'asleepCore', 'asleepDeep', 'asleepREM'])

// Groups sleepAnalysis samples into nights (keyed by the local date the sleep ended).
// Returns NEWEST FIRST — the opposite of dailySeries and queryDaily, which run oldest first.
// Taking `[length - 1]` here means the oldest night, which is usually one the window cut in half.
// When several sources recorded the same night (Watch, iPhone, third-party), the source
// with the most asleep time is reported so stages are not double counted.
/**
 * The same instant written in the user's own clock, "2026-10-27 23:25".
 *
 * Everything stored here is UTC, which reads as a different evening in Bangkok: a bedtime of
 * 16:25Z is 23:25 local. A reader who forgets to convert reports the wrong hour, and that has
 * already happened — so the local reading travels with the timestamp rather than being left as
 * an exercise for whoever renders it.
 */
export function localClock(iso: string | undefined, timeZone: string) {
  if (!iso) return undefined
  const at = new Date(iso)
  if (Number.isNaN(at.getTime())) return undefined
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  }).formatToParts(at)
  const get = (type: string) => parts.find((p) => p.type === type)?.value ?? '00'
  return `${get('year')}-${get('month')}-${get('day')} ${get('hour')}:${get('minute')}`
}

/** Minutes covered by a set of intervals, counting overlap once. Two sources recording the
 *  same night, or a stage sample inside another, must not add up to twice the sleep. */
function unionMinutes(intervals: { from: number; to: number }[]) {
  const sorted = [...intervals].sort((a, b) => a.from - b.from)
  let total = 0
  let cursor = -Infinity
  for (const { from, to } of sorted) {
    const start = Math.max(from, cursor)
    if (to > start) total += to - start
    cursor = Math.max(cursor, to)
  }
  return total / 60_000
}

export async function querySleep(uid: string, range: Range, timeZone: string) {
  const samples = await querySamples(uid, 'sleepAnalysis', range, 5000)
  const dayOf = new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' })
  const hourOf = new Intl.DateTimeFormat('en-GB', { timeZone, hour: '2-digit', hour12: false })

  // Sleep is recorded as stretches, not calendar days. Grouping by the date a sample ends on
  // puts an afternoon nap in the same bucket as the night before it, which showed up as a night
  // two hours longer than it was with a wake time in the evening.
  type Piece = { source: string; label: string; from: number; to: number }
  type Stretch = { start: number; end: number; pieces: Piece[] }
  const GAP_MS = 60 * 60_000
  const stretches: Stretch[] = []

  const pieces = samples
    .map((s) => ({
      source: String(s.sourceName ?? 'unknown'),
      label: String(s.valueLabel ?? s.value),
      from: new Date(String(s.startDate)).getTime(),
      to: new Date(String(s.endDate)).getTime(),
    }))
    .filter((p) => Number.isFinite(p.from) && Number.isFinite(p.to))
    .sort((a, b) => a.from - b.from)

  for (const piece of pieces) {
    const current = stretches[stretches.length - 1]
    if (current && piece.from - current.end <= GAP_MS) {
      current.pieces.push(piece)
      if (piece.to > current.end) current.end = piece.to
      continue
    }
    stretches.push({ start: piece.from, end: piece.to, pieces: [piece] })
  }

  interface Night {
    date: string
    source: string
    otherSources: string[]
    bedtime: string
    wakeTime: string
    asleepMinutes: number
    sleepWindowMinutes: number
    stagesMinutes: Record<string, number>
    naps: { time: string; asleepMinutes: number }[]
  }

  // One stretch can be covered by the phone and the watch at once; the fuller recording wins and
  // the other is named, rather than both being added together.
  const describe = (stretch: Stretch, date: string): Night => {
    const bySource = new Map<string, Piece[]>()
    for (const piece of stretch.pieces) bySource.set(piece.source, [...(bySource.get(piece.source) ?? []), piece])

    const scored = [...bySource.entries()]
      .map(([source, list]) => ({
        source,
        list,
        asleep: unionMinutes(list.filter((p) => ASLEEP.has(p.label))),
      }))
      .sort((a, b) => b.asleep - a.asleep)
    const best = scored[0]!

    const stages: Record<string, number> = {}
    for (const label of new Set(best.list.map((p) => p.label))) {
      stages[label] = Math.round(unionMinutes(best.list.filter((p) => p.label === label)))
    }

    return {
      date,
      source: best.source,
      otherSources: scored.slice(1).map((s) => s.source),
      bedtime: new Date(Math.min(...best.list.map((p) => p.from))).toISOString(),
      wakeTime: new Date(Math.max(...best.list.map((p) => p.to))).toISOString(),
      asleepMinutes: Math.round(best.asleep),
      // First sample to last, awake stretches included. This is not time in bed: Apple only
      // knows that when the user has the inBed stage turned on, and it lands in stagesMinutes.
      sleepWindowMinutes: Math.round(unionMinutes(best.list)),
      stagesMinutes: stages,
      naps: [],
    }
  }

  const nights = new Map<string, Night>()
  const napsByDate = new Map<string, { time: string; asleepMinutes: number }[]>()

  for (const stretch of stretches) {
    const date = dayOf.format(new Date(stretch.end))
    const night = describe(stretch, date)
    const endedInTheMorning = Number(hourOf.format(new Date(stretch.end))) < NIGHT_ENDS_BEFORE_HOUR

    if (endedInTheMorning || night.asleepMinutes >= NIGHT_MINUTES) {
      // A night broken by an hour awake arrives as two stretches; they are the same night.
      const existing = nights.get(date)
      if (!existing) {
        nights.set(date, night)
        continue
      }
      existing.asleepMinutes += night.asleepMinutes
      existing.sleepWindowMinutes += night.sleepWindowMinutes
      if (night.wakeTime > existing.wakeTime) existing.wakeTime = night.wakeTime
      if (night.bedtime < existing.bedtime) existing.bedtime = night.bedtime
      for (const [label, value] of Object.entries(night.stagesMinutes)) {
        existing.stagesMinutes[label] = (existing.stagesMinutes[label] ?? 0) + value
      }
      continue
    }

    napsByDate.set(date, [...(napsByDate.get(date) ?? []), { time: night.wakeTime, asleepMinutes: night.asleepMinutes }])
  }

  for (const [date, naps] of napsByDate) {
    const night = nights.get(date)
    if (night) night.naps = naps
    else {
      nights.set(date, {
        date,
        source: 'unknown',
        otherSources: [],
        bedtime: naps[0]!.time,
        wakeTime: naps[naps.length - 1]!.time,
        asleepMinutes: 0,
        sleepWindowMinutes: 0,
        stagesMinutes: {},
        naps,
      })
    }
  }

  // The local reading is derived once, at the end: carrying a second copy through the merge
  // above let the two drift apart the moment a night arrived in two stretches.
  return [...nights.values()]
    .sort((a, b) => b.date.localeCompare(a.date))
    .map((night) => ({
      ...night,
      bedtimeLocal: localClock(night.bedtime, timeZone),
      wakeTimeLocal: localClock(night.wakeTime, timeZone),
      naps: night.naps.map((nap) => ({ ...nap, timeLocal: localClock(nap.time, timeZone) })),
    }))
}
