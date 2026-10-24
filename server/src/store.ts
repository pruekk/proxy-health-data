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

// Firestore layout
//   users/{uid}                                  profile: timeZone, lastSyncAt
//   users/{uid}/metrics/{type}                   one doc per HealthKit metric (kind, unit, lastSyncAt)
//   users/{uid}/metrics/{type}/samples/{uuid}    raw HealthKit samples
//   users/{uid}/workouts/{uuid}                  HKWorkout (Apple Fitness / Watch workouts)
//   users/{uid}/daily/{yyyy-MM-dd}               per-day aggregates (metrics.*) + activity rings (activity)

const BATCH_LIMIT = 450
/** Years of raw samples kept when the user has not chosen otherwise. */
export const DEFAULT_RETENTION_YEARS = 2

const userRef = (uid: string) => db.collection('users').doc(uid)
const metricsCol = (uid: string) => userRef(uid).collection('metrics')
const samplesCol = (uid: string, type: string) => metricsCol(uid).doc(type).collection('samples')
const workoutsCol = (uid: string) => userRef(uid).collection('workouts')
const dailyCol = (uid: string) => userRef(uid).collection('daily')
const hourlyCol = (uid: string) => userRef(uid).collection('hourly')
const syncsCol = (uid: string) => userRef(uid).collection('syncs')

/** Metrics whose raw samples only live for a few days unless recorded during a workout. */
const SHORT_RETENTION = new Set(catalog.quantities.filter((q) => q.retention === 'short').map((q) => q.key))
/** Metrics that never expire: a handful of samples a month, and history that cannot be rebuilt. */
const KEEP_FOREVER = new Set(
  [...catalog.quantities, ...catalog.categories].filter((m) => m.retention === 'keep').map((m) => m.key),
)

type Op = (batch: WriteBatch) => void

async function commit(ops: Op[]) {
  for (let i = 0; i < ops.length; i += BATCH_LIMIT) {
    const batch = db.batch()
    for (const op of ops.slice(i, i + BATCH_LIMIT)) op(batch)
    await batch.commit()
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
  if (retentionYears <= 0 || KEEP_FOREVER.has(s.type)) return undefined
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
function hourlyDocs(stats: HourlyStatInput[]): Map<string, DocumentData> {
  const days = new Map<string, DocumentData>()
  for (const { date, hour, type, ...values } of stats) {
    let doc = days.get(date)
    if (!doc) days.set(date, (doc = { date, metrics: {} }))
    doc.metrics[type] ??= {}
    doc.metrics[type][hour] = values
  }
  return days
}

function dailyDocs(stats: DailyStatInput[], rings: ActivitySummaryInput[]): Map<string, DocumentData> {
  const days = new Map<string, DocumentData>()
  const day = (date: string) => {
    let doc = days.get(date)
    if (!doc) days.set(date, (doc = { date, metrics: {} }))
    return doc
  }
  for (const { date, type, ...values } of stats) day(date).metrics[type] = values
  for (const { date, ...activity } of rings) day(date).activity = activity
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
    doc.sources = Object.fromEntries([...sources].map(([source, count]) => [source, FieldValue.increment(count)]))
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
export async function applyRetention(uid: string, scope: string, dryRun: boolean) {
  const years = await getRetentionYears(uid)
  const longMs = years * 365.25 * 86_400_000
  const shortMs = catalog.sync.shortRetentionDays * 86_400_000
  const writer = db.bulkWriter()
  let scanned = 0
  let stamped = 0

  const stamp = (ref: FirebaseFirestore.DocumentReference, at: number, keepLong: boolean) => {
    stamped += 1
    if (!dryRun) writer.set(ref, { expiresAt: Timestamp.fromMillis(at + (keepLong ? longMs : shortMs)) }, { merge: true })
  }

  if (scope === 'daily' || scope === 'hourly' || scope === 'workouts') {
    const col = scope === 'daily' ? dailyCol(uid) : scope === 'hourly' ? hourlyCol(uid) : workoutsCol(uid)
    const snap = await col.get()
    for (const doc of snap.docs) {
      scanned += 1
      if (doc.get('expiresAt')) continue
      const start = doc.get('startDate') as Timestamp | undefined
      const at = start ? start.toMillis() : new Date(`${doc.id}T00:00:00Z`).getTime()
      if (Number.isFinite(at)) stamp(doc.ref, at, true)
    }
  } else if (KEEP_FOREVER.has(scope)) {
    return { scope, scanned: 0, stamped: 0, retentionYears: years, dryRun, kept: true }
  } else {
    const short = SHORT_RETENTION.has(scope)
    let intervals: { from: number; to: number }[] = []
    if (short) {
      const workouts = await workoutsCol(uid).get()
      intervals = workouts.docs.map((d) => ({
        from: (d.get('startDate') as Timestamp).toMillis(),
        to: (d.get('endDate') as Timestamp).toMillis() + catalog.sync.recoveryTailSeconds * 1000,
      }))
    }
    const snap = await samplesCol(uid, scope).get()
    for (const doc of snap.docs) {
      scanned += 1
      if (doc.get('expiresAt')) continue
      const start = doc.get('startDate') as Timestamp | undefined
      if (!start) continue
      const at = start.toMillis()
      const keepLong = !short || doc.get('context') === 'workout' || intervals.some((i) => at >= i.from && at <= i.to)
      stamp(doc.ref, at, keepLong)
    }
  }

  if (!dryRun) await writer.close()
  return { scope, scanned, stamped, retentionYears: years, dryRun }
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

export async function listMetrics(uid: string, types?: string[], withSources = false) {
  const snap = await metricsCol(uid).get()
  const docs = types?.length ? snap.docs.filter((d) => types.includes(d.id)) : snap.docs
  return Promise.all(
    docs.map(async (doc) => {
      const { latest, sources, ...rest } = plain(doc.data())
      // Docs written before `latest` was denormalised still need the old per-metric query.
      const resolved = latest ?? (await legacyLatest(uid, doc.id))
      const base = { ...rest, type: doc.id, latest: resolved ?? null }
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
