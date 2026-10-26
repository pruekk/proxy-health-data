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
import { computeBattery, type BatteryInputs } from './battery'
import type { ReadinessInputs } from './readiness'

// Firestore layout
//   users/{uid}                                  profile: timeZone, lastSyncAt
//   users/{uid}/metrics/{type}                   one doc per HealthKit metric (kind, unit, lastSyncAt)
//   users/{uid}/metrics/{type}/samples/{uuid}    raw HealthKit samples
//   users/{uid}/workouts/{uuid}                  HKWorkout (Apple Fitness / Watch workouts)
//   users/{uid}/daily/{yyyy-MM-dd}               per-day aggregates (metrics.*) + activity rings (activity)

const BATCH_LIMIT = 450
/** Years of raw samples kept when the user has not chosen otherwise. */
export const DEFAULT_RETENTION_YEARS = 2
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

/** Metrics whose raw samples only live for a few days unless recorded during a workout. */
const SHORT_RETENTION = new Set(catalog.quantities.filter((q) => q.retention === 'short').map((q) => q.key))

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
export function sampleExpiry(s: SampleInput, retentionYears: number): Timestamp | undefined {
  if (retentionYears <= 0) return undefined
  const short = SHORT_RETENTION.has(s.type) && s.context !== 'workout'
  const days = short ? catalog.sync.shortRetentionDays : retentionYears * 365.25
  return Timestamp.fromMillis(new Date(s.startDate).getTime() + days * 86_400_000)
}

const retentionExpiry = (retentionYears: number, from: Date) =>
  retentionYears > 0 ? Timestamp.fromMillis(from.getTime() + retentionYears * 365.25 * 86_400_000) : undefined

function sampleDoc(s: SampleInput, retentionYears: number): DocumentData {
  return {
    expiresAt: sampleExpiry(s, retentionYears),
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

function workoutDoc(w: WorkoutInput, retentionYears: number): DocumentData {
  const { id, startDate, endDate, ...rest } = w
  return {
    ...rest,
    startDate: toTimestamp(startDate),
    endDate: toTimestamp(endDate),
    expiresAt: retentionExpiry(retentionYears, new Date(startDate)),
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

export async function getRetentionYears(uid: string): Promise<number> {
  const snap = await userRef(uid).get()
  const value = snap.get('retentionYears')
  return typeof value === 'number' ? value : DEFAULT_RETENTION_YEARS
}

export async function setRetentionYears(uid: string, years: number) {
  await userRef(uid).set({ retentionYears: years }, { merge: true })
}

export async function ingest(uid: string, body: SyncBody) {
  const now = FieldValue.serverTimestamp()
  const retentionYears = await getRetentionYears(uid)
  const ops: Op[] = []
  // Per type: the newest sample and a count per recording source, both denormalised onto the
  // metric document below so reads never fan out one query per metric.
  const touchedMetrics = new Map<
    string,
    { kind: string; unit?: string; newest?: SampleInput; oldest?: string; count: number; sources: Map<string, number> }
  >()

  for (const s of body.samples ?? []) {
    const doc = sampleDoc(s, retentionYears)
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
    const doc = workoutDoc(w, retentionYears)
    ops.push((b) => b.set(workoutsCol(uid).doc(w.id), doc))
  }
  for (const id of body.deletedWorkoutIds ?? []) ops.push((b) => b.delete(workoutsCol(uid).doc(id)))

  const days = dailyDocs(body.dailyStats ?? [], body.activitySummaries ?? [])
  for (const [date, doc] of days) {
    const expiresAt = retentionExpiry(retentionYears, new Date(`${date}T00:00:00Z`))
    ops.push((b) => b.set(dailyCol(uid).doc(date), { ...doc, expiresAt, updatedAt: now }, { merge: true }))
  }

  const hours = hourlyDocs(body.hourlyStats ?? [])
  for (const [date, doc] of hours) {
    const expiresAt = retentionExpiry(retentionYears, new Date(`${date}T00:00:00Z`))
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

  const latestAndBaseline = (type: string) => {
    const values = (series[type] ?? []).map((p) => p.avg ?? p.sum).filter((v): v is number => typeof v === 'number')
    if (values.length < 2) return undefined
    return { latest: values[values.length - 1]!, baseline: values.reduce((a, b) => a + b, 0) / values.length }
  }

  // Acute load is the last week of exercise minutes, chronic the whole window.
  const exercise = (series.appleExerciseTime ?? []).map((p) => p.sum ?? 0)
  const load = exercise.length >= 7
    ? {
        acute: exercise.slice(-7).reduce((a, b) => a + b, 0) / 7,
        chronic: exercise.reduce((a, b) => a + b, 0) / exercise.length,
      }
    : undefined

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
  const stages = (lastNight?.stagesMinutes ?? {}) as Record<string, number>
  const inBedMinutes = typeof stages.inBed === 'number' ? stages.inBed : undefined

  return {
    hrv: latestAndBaseline('heartRateVariabilitySDNN'),
    restingHeartRate: latestAndBaseline('restingHeartRate'),
    sleepMinutes,
    inBedMinutes,
    load,
  }
}

/**
 * Inputs for the body battery: last night's sleep, the resting pulse it is measured against, and
 * today's hourly energy and heart rate since waking.
 */
/** Days of hourly history used for the "usual at this hour" comparison. */
const BATTERY_HISTORY_DAYS = 7

export async function collectBatteryInputs(uid: string): Promise<BatteryInputs> {
  const timeZone = String((await getProfile(uid)).timeZone ?? 'UTC')
  const now = new Date()
  const key = (date: Date) =>
    new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' }).format(date)
  const today = key(now)

  const historyFrom = key(new Date(now.getTime() - BATTERY_HISTORY_DAYS * 86_400_000))
  const [hourly, series, nights] = await Promise.all([
    queryHourly(uid, historyFrom, today, ['activeEnergyBurned', 'heartRate']),
    dailySeries(uid, key(new Date(now.getTime() - 30 * 86_400_000)), today, ['restingHeartRate']),
    querySleep(uid, { from: new Date(now.getTime() - (BATTERY_HISTORY_DAYS + 1) * 86_400_000), to: now }, timeZone),
  ])

  const lastNight = nights
    .filter((n): n is typeof n & { date: string } => typeof n.date === 'string')
    .sort((a, b) => b.date.localeCompare(a.date))[0]
  const restingSeries = (series.restingHeartRate ?? []).map((p) => p.avg).filter((v): v is number => typeof v === 'number')

  // Hours since waking. Before any sleep is known, the whole day counts.
  const wokeAt = lastNight?.wakeTime ? new Date(String(lastNight.wakeTime)) : undefined
  const firstHour = wokeAt && key(wokeAt) === today ? Number(new Intl.DateTimeFormat('en-GB', { timeZone, hour: '2-digit', hour12: false }).format(wokeAt)) : 0

  const hoursOf = (day: { metrics?: unknown } | undefined, from: number) => {
    const metrics = (day?.metrics ?? {}) as Record<string, Record<string, { sum?: number; avg?: number }>>
    const hours: BatteryInputs['hours'] = []
    for (let hour = from; hour <= 23; hour += 1) {
      const energy = metrics.activeEnergyBurned?.[hour]?.sum
      const heartRate = metrics.heartRate?.[hour]?.avg
      if (energy === undefined && heartRate === undefined) continue
      hours.push({ hour, activeEnergyKcal: energy, heartRate })
    }
    return hours
  }

  const byDate = new Map(hourly.map((day) => [String((day as { date?: string }).date), day]))
  const sleepByDate = new Map(
    nights
      .filter((n): n is typeof n & { date: string } => typeof n.date === 'string')
      .map((n) => [n.date, typeof n.asleepMinutes === 'number' ? n.asleepMinutes : undefined]),
  )
  const restingHeartRate = restingSeries.length ? restingSeries[restingSeries.length - 1] : undefined

  // "Usual at this hour" is the same simulation run over the previous days, cut off at the
  // current hour, so the comparison is like-for-like rather than against a whole-day average.
  const hourNow = Number(new Intl.DateTimeFormat('en-GB', { timeZone, hour: '2-digit', hour12: false }).format(now))
  const past: number[] = []
  for (let back = 1; back <= BATTERY_HISTORY_DAYS; back += 1) {
    const date = key(new Date(now.getTime() - back * 86_400_000))
    const day = byDate.get(date)
    if (!day) continue
    const hours = hoursOf(day, 0).filter((h) => h.hour <= hourNow)
    if (!hours.length) continue
    past.push(computeBattery({ sleepMinutes: sleepByDate.get(date), restingHeartRate, hours }).level)
  }

  return {
    sleepMinutes: typeof lastNight?.asleepMinutes === 'number' ? lastNight.asleepMinutes : undefined,
    restingHeartRate,
    hours: hoursOf(byDate.get(today), firstHour),
    usualAtThisHour: past.length ? past.reduce((sum, level) => sum + level, 0) / past.length : undefined,
  }
}

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
  const years = await getRetentionYears(uid)
  const longMs = years * 365.25 * 86_400_000
  const shortMs = catalog.sync.shortRetentionDays * 86_400_000
  let scanned = 0
  let stamped = 0
  // Batched commits rather than a BulkWriter: the same path ingest uses, and a failed write
  // surfaces as a rejected commit instead of an unhandled rejection that kills the instance.
  let ops: Op[] = []

  // Only ever brings an expiry forward. A document that already expires sooner than the rule
  // would set is left alone, so re-running this can never resurrect data.
  const stamp = (ref: FirebaseFirestore.DocumentReference, at: number, keepLong: boolean, current?: Timestamp) => {
    const target = at + (keepLong ? longMs : shortMs)
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
  const short = !isDated && SHORT_RETENTION.has(scope)
  let intervals: { from: number; to: number }[] = []
  if (short) {
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
      const keepLong = !short || doc.get('context') === 'workout' || intervals.some((i) => at >= i.from && at <= i.to)
      stamp(doc.ref, at, keepLong, current)
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
  return { scope, scanned, stamped, retentionYears: years, dryRun, done, after: done ? undefined : cursor }
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
      const base = { ...rest, type: doc.id, latest: resolved ?? null, ...(withCounts ? { count } : {}) }
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

export async function queryWorkouts(uid: string, range: Range, limit: number, activityType?: string) {
  // Equality on activityTypeName is served by the automatic single-field index, so an activity
  // filter no longer means reading 1000 docs and throwing most of them away.
  let query = workoutsCol(uid)
    .where('startDate', '>=', Timestamp.fromDate(range.from))
    .where('startDate', '<', Timestamp.fromDate(range.to))
  if (activityType) query = query.where('activityTypeName', '==', activityType)
  const snap = await query.orderBy('startDate', 'desc').limit(limit).get()
  return snap.docs.map((d): DocumentData => {
    const data = plain(d.data())
    return { id: d.id, ...data, ...weatherOf(data.metadata) }
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
export async function querySleep(uid: string, range: Range, timeZone: string) {
  const samples = await querySamples(uid, 'sleepAnalysis', range, 5000)
  const dayOf = new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' })

  type Night = { start: string; end: string; stages: Record<string, number>; asleep: number }
  const nights = new Map<string, Map<string, Night>>()

  for (const s of samples) {
    const night = dayOf.format(new Date(s.endDate))
    const source = String(s.sourceName ?? 'unknown')
    const label = String(s.valueLabel ?? s.value)
    const minutes = (new Date(s.endDate).getTime() - new Date(s.startDate).getTime()) / 60000

    let bySource = nights.get(night)
    if (!bySource) nights.set(night, (bySource = new Map()))
    let n = bySource.get(source)
    if (!n) bySource.set(source, (n = { start: s.startDate, end: s.endDate, stages: {}, asleep: 0 }))

    n.stages[label] = (n.stages[label] ?? 0) + minutes
    if (ASLEEP.has(label)) n.asleep += minutes
    if (s.startDate < n.start) n.start = s.startDate
    if (s.endDate > n.end) n.end = s.endDate
  }

  const round = (m: number) => Math.round(m)
  return [...nights.entries()]
    .sort(([a], [b]) => b.localeCompare(a))
    .map(([date, bySource]) => {
      const [source, best] = [...bySource.entries()].sort(([, a], [, b]) => b.asleep - a.asleep)[0]!
      return {
        date,
        source,
        otherSources: [...bySource.keys()].filter((s) => s !== source),
        bedtime: best.start,
        wakeTime: best.end,
        asleepMinutes: round(best.asleep),
        stagesMinutes: Object.fromEntries(Object.entries(best.stages).map(([k, v]) => [k, round(v)])),
      }
    })
}
