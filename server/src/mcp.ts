// Minimal stateless MCP server (Streamable HTTP transport, JSON responses).
// Spec: https://modelcontextprotocol.io/specification — supports initialize, ping, tools/list, tools/call.

import { parseDateKeys, parseRange } from './dates'
import {
  BadRequest,
  dailySeries,
  getProfile,
  getWorkout,
  latestDailyValues,
  listMetrics,
  queryDaily,
  querySamples,
  querySleep,
  queryWorkouts,
} from './store'

const SUPPORTED_VERSIONS = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05']
const SERVER_INFO = { name: 'proxy-health-data', title: 'Proxy Health Data', version: '1.0.0' }

const INSTRUCTIONS = `Read-only access to the user's Apple Health and Apple Fitness data, synced from their iPhone.
Start with list_metrics to see which metrics exist and when they were last updated.
Prefer get_daily_summaries for totals and trends (steps, energy, activity rings, resting heart rate): its values are de-duplicated on-device.
Use get_samples only for intraday detail. Units are given on every value. Dates in daily summaries are the user's local dates.`

type Json = Record<string, unknown>
type Args = Record<string, unknown>

interface Tool {
  name: string
  title: string
  description: string
  inputSchema: Json
  run: (uid: string, args: Args) => Promise<unknown>
}

const str = (v: unknown) => (typeof v === 'string' && v.length ? v : undefined)
const num = (v: unknown, fallback: number, max: number) => {
  const n = typeof v === 'number' ? v : Number(v)
  return Number.isFinite(n) && n > 0 ? Math.min(Math.floor(n), max) : fallback
}
const timeZoneOf = async (uid: string) => String((await getProfile(uid)).timeZone ?? 'UTC')

const range = {
  from: { type: 'string', description: 'Start, ISO date or datetime. Defaults to 7 days before `to`.' },
  to: { type: 'string', description: 'End, ISO date or datetime (a bare date includes that whole day). Defaults to now.' },
}
const dayRange = {
  from: { type: 'string', description: 'First local date, YYYY-MM-DD. Defaults to 7 days before `to`.' },
  to: { type: 'string', description: 'Last local date, YYYY-MM-DD (inclusive). Defaults to today.' },
}


// ---------- derived metrics ----------

const BODY_METRICS = ['bodyMass', 'height', 'bodyMassIndex', 'bodyFatPercentage', 'leanBodyMass', 'waistCircumference']
const CARDIO_METRICS = ['vo2Max', 'restingHeartRate', 'heartRateVariabilitySDNN', 'heartRateRecoveryOneMinute', 'walkingHeartRateAverage']

// VO2 max percentiles (mL/kg/min) from the Cooper Institute norms reproduced in the ACSM
// Guidelines. Apple does not publish the cutoffs behind its own Cardio Fitness levels — they
// only exist inside the Health app — so these bands are a documented stand-in, not Apple's.
// 70+ reuses the 60-69 band, which is the oldest the source covers.
const VO2_PERCENTILES: Record<string, { band: string; p25: number; p50: number; p75: number }[]> = {
  male: [
    { band: '20-29', p25: 40.1, p50: 48.0, p75: 55.2 },
    { band: '30-39', p25: 35.9, p50: 42.4, p75: 49.2 },
    { band: '40-49', p25: 31.9, p50: 37.8, p75: 45.0 },
    { band: '50-59', p25: 27.1, p50: 32.6, p75: 39.7 },
    { band: '60+', p25: 23.7, p50: 28.2, p75: 34.5 },
  ],
  female: [
    { band: '20-29', p25: 30.5, p50: 37.6, p75: 44.7 },
    { band: '30-39', p25: 25.3, p50: 30.2, p75: 36.1 },
    { band: '40-49', p25: 22.1, p50: 26.7, p75: 32.4 },
    { band: '50-59', p25: 19.9, p50: 23.4, p75: 27.6 },
    { band: '60+', p25: 17.2, p50: 20.0, p75: 23.8 },
  ],
}

const ageFrom = (dateOfBirth: unknown) => {
  const dob = typeof dateOfBirth === 'string' ? new Date(dateOfBirth) : null
  if (!dob || Number.isNaN(dob.getTime())) return undefined
  const now = new Date()
  let age = now.getUTCFullYear() - dob.getUTCFullYear()
  const monthDay = now.getUTCMonth() * 100 + now.getUTCDate()
  if (monthDay < dob.getUTCMonth() * 100 + dob.getUTCDate()) age -= 1
  return age >= 0 && age < 120 ? age : undefined
}

function classifyVo2(value: number, age?: number, sex?: unknown) {
  const table = VO2_PERCENTILES[sex === 'female' ? 'female' : sex === 'male' ? 'male' : '']
  if (!table || age === undefined) {
    return { level: null, note: 'Needs date of birth and biological sex from HealthKit to classify.' }
  }
  if (age < 20) return { level: null, note: 'Reference values start at age 20.' }
  const row = table.find((r) => age <= Number(r.band.split('-')[1] ?? 200)) ?? table[table.length - 1]!
  const level = value < row.p25 ? 'low' : value < row.p50 ? 'below average' : value < row.p75 ? 'above average' : 'high'
  return {
    level,
    ageBand: row.band,
    percentileCutoffs: { p25: row.p25, p50: row.p50, p75: row.p75 },
    basis: 'Cooper Institute / ACSM percentiles, not Apple\'s own Cardio Fitness table',
  }
}

// first/last/min/avg/max over a daily series, picking whichever field the metric uses.
function summarize(points: DocumentDataLike[]) {
  const values = points.map((p) => (typeof p.sum === 'number' ? p.sum : p.avg)).filter((v): v is number => typeof v === 'number')
  if (!values.length) return null
  const mins = points.map((p) => p.min).filter((v): v is number => typeof v === 'number')
  const maxes = points.map((p) => p.max).filter((v): v is number => typeof v === 'number')
  const first = values[0]!
  const last = values[values.length - 1]!
  return {
    days: values.length,
    first: { date: points[0]!.date, value: first },
    last: { date: points[points.length - 1]!.date, value: last },
    change: Number((last - first).toFixed(3)),
    avg: Number((values.reduce((a, b) => a + b, 0) / values.length).toFixed(3)),
    min: Math.min(...(mins.length ? mins : values)),
    max: Math.max(...(maxes.length ? maxes : values)),
  }
}

type DocumentDataLike = Record<string, unknown> & { date?: string; sum?: number; avg?: number; min?: number; max?: number }

const tools: Tool[] = [
  {
    name: 'list_metrics',
    title: 'List metrics',
    description:
      'List every HealthKit metric synced for this user (e.g. stepCount, heartRate, restingHeartRate, sleepAnalysis, vo2Max) with its unit, kind and most recent sample. Also returns the profile (time zone, last sync time). Set `withSources` to see which apps and devices report each metric — a metric with several sources can look duplicated in raw samples.',
    inputSchema: {
      type: 'object',
      properties: {
        withSources: { type: 'boolean', description: 'Include the recording apps/devices per metric with sample counts.' },
      },
    },
    run: async (uid, args) => ({
      profile: await getProfile(uid),
      metrics: await listMetrics(uid, undefined, args.withSources === true),
    }),
  },
  {
    name: 'get_daily_summaries',
    title: 'Daily summaries',
    description:
      'Per-day aggregates: sums for cumulative metrics (stepCount, activeEnergyBurned, distanceWalkingRunning, appleExerciseTime…), avg/min/max for discrete metrics (heartRate, restingHeartRate, heartRateVariabilitySDNN, bodyMass…), plus Apple Fitness activity rings (move/exercise/stand and goals). Best tool for totals and trends.',
    inputSchema: {
      type: 'object',
      properties: {
        ...dayRange,
        metrics: { type: 'array', items: { type: 'string' }, description: 'Optional metric keys to include. Omit for all.' },
      },
    },
    run: async (uid, args) => {
      const keys = parseDateKeys(str(args.from), str(args.to), 7, await timeZoneOf(uid))
      const metrics = Array.isArray(args.metrics) ? args.metrics.map(String) : undefined
      return { ...keys, days: await queryDaily(uid, keys.from, keys.to, metrics) }
    },
  },
  {
    name: 'get_samples',
    title: 'Raw samples',
    description:
      'Raw HealthKit samples for one metric in a time range, newest first. Use for intraday detail (e.g. heart rate during an afternoon). Use list_metrics for valid `type` keys.',
    inputSchema: {
      type: 'object',
      properties: {
        type: { type: 'string', description: 'Metric key, e.g. heartRate, stepCount, oxygenSaturation.' },
        ...range,
        source: {
          type: 'string',
          description: 'Keep only samples whose recording app or device matches (substring, case-insensitive), e.g. "Watch". Use list_metrics with withSources to see the options.',
        },
        limit: { type: 'number', description: 'Max samples (default 200, max 1000).' },
      },
      required: ['type'],
    },
    run: async (uid, args) => {
      const type = str(args.type)
      if (!type || !/^[A-Za-z0-9_]{1,80}$/.test(type)) throw new BadRequest('`type` is required, e.g. "heartRate"')
      const source = str(args.source)
      const samples = await querySamples(uid, type, parseRange(str(args.from), str(args.to), 7), num(args.limit, 200, 1000), source)
      return { type, count: samples.length, source: source || undefined, samples }
    },
  },
  {
    name: 'get_workouts',
    title: 'Workouts',
    description:
      'Workouts recorded by Apple Watch / Apple Fitness / other apps, newest first: type, duration, active energy, distance, heart rate, elevation, power.',
    inputSchema: {
      type: 'object',
      properties: {
        ...range,
        activityType: { type: 'string', description: 'Optional filter, e.g. running, cycling, walking, traditionalStrengthTraining.' },
        limit: { type: 'number', description: 'Max workouts (default 50, max 500).' },
      },
    },
    run: async (uid, args) => {
      const workouts = await queryWorkouts(uid, parseRange(str(args.from), str(args.to), 30), num(args.limit, 50, 500), str(args.activityType))
      return { count: workouts.length, workouts }
    },
  },
  {
    name: 'get_sleep',
    title: 'Sleep',
    description:
      'Nightly sleep: bedtime, wake time, total asleep minutes and minutes per stage (asleepCore, asleepDeep, asleepREM, awake, inBed). Nights are keyed by the local date sleep ended.',
    inputSchema: { type: 'object', properties: { ...range } },
    run: async (uid, args) => {
      const r = parseRange(str(args.from), str(args.to), 7)
      // Pull samples from 18h earlier so the first night's bedtime is included.
      const nights = await querySleep(uid, { from: new Date(r.from.getTime() - 18 * 3_600_000), to: r.to }, await timeZoneOf(uid))
      return { nights }
    },
  },
  {
    name: 'get_latest_values',
    title: 'Latest values',
    description:
      'Most recent reading for the metrics you name (weight, height, VO2 max, resting heart rate, body fat…), in one call. Much smaller than list_metrics when you only need current values. Omit `types` for every metric.',
    inputSchema: {
      type: 'object',
      properties: {
        types: {
          type: 'array',
          items: { type: 'string' },
          description: 'Metric keys, e.g. ["bodyMass", "height", "vo2Max"]. Omit for all metrics.',
        },
      },
    },
    run: async (uid, args) => {
      const types = Array.isArray(args.types) ? args.types.map(String) : undefined
      const [metrics, daily] = await Promise.all([listMetrics(uid, types), latestDailyValues(uid, types)])

      const values = metrics.map((metric) => {
        const { type, latest, unit } = metric as { type: string; latest: Record<string, unknown> | null; unit?: string }
        return {
          type,
          value: latest?.value ?? null,
          unit: unit ?? latest?.unit ?? null,
          valueLabel: latest?.valueLabel,
          at: latest?.startDate ?? null,
          source: latest?.sourceName ?? null,
          from: 'sample',
        }
      })

      // Metrics recorded less often than the raw-sample window (weight, body fat, BMI…) have no
      // recent sample, but their daily aggregate is still the current value.
      const covered = new Set(values.filter((v) => v.value !== null).map((v) => v.type))
      for (const [type, day] of Object.entries(daily)) {
        if (covered.has(type)) continue
        const value = (day.avg ?? day.sum) as number | undefined
        if (value === undefined) continue
        const existing = values.find((v) => v.type === type)
        const fallback = { type, value, unit: (day.unit as string) ?? null, at: day.date as string, source: null, from: 'daily' }
        if (existing) Object.assign(existing, fallback)
        else values.push({ ...fallback, valueLabel: undefined })
      }
      return { values }
    },
  },
  {
    name: 'get_metric_stats',
    title: 'Metric stats and trend',
    description:
      'First, last, change, average, min and max for each requested metric over a date range, computed from the de-duplicated daily aggregates. Use this for "is my VO2 max improving?" or "how much weight did I lose?" instead of pulling raw samples.',
    inputSchema: {
      type: 'object',
      properties: {
        types: { type: 'array', items: { type: 'string' }, description: 'Metric keys to summarise.' },
        ...dayRange,
      },
      required: ['types'],
    },
    run: async (uid, args) => {
      const types = Array.isArray(args.types) ? args.types.map(String) : []
      if (!types.length) throw new BadRequest('`types` is required, e.g. ["vo2Max", "bodyMass"]')
      const keys = parseDateKeys(str(args.from), str(args.to), 90, await timeZoneOf(uid))
      const series = await dailySeries(uid, keys.from, keys.to, types)
      return {
        ...keys,
        metrics: Object.fromEntries(types.map((type) => [type, summarize((series[type] ?? []) as DocumentDataLike[])])),
      }
    },
  },
  {
    name: 'get_body_composition',
    title: 'Body composition',
    description:
      'Weight, height, BMI, body fat, lean mass and waist circumference as one aligned daily series, plus the latest value of each. BMI is derived from weight and height on days HealthKit has no BMI of its own.',
    inputSchema: { type: 'object', properties: { ...dayRange } },
    run: async (uid, args) => {
      const keys = parseDateKeys(str(args.from), str(args.to), 90, await timeZoneOf(uid))
      const series = await dailySeries(uid, keys.from, keys.to, BODY_METRICS)
      const latestHeight = (series.height ?? []).at(-1)?.avg as number | undefined

      const byDate = new Map<string, Record<string, unknown>>()
      for (const [type, points] of Object.entries(series)) {
        for (const point of points) {
          const row: Record<string, unknown> = byDate.get(String(point.date)) ?? { date: point.date }
          row[type] = point.avg ?? point.sum
          byDate.set(String(point.date), row)
        }
      }
      for (const row of byDate.values()) {
        const mass = row.bodyMass as number | undefined
        const height = (row.height as number | undefined) ?? latestHeight
        if (row.bodyMassIndex === undefined && mass && height) {
          row.derivedBodyMassIndex = Number((mass / (height * height)).toFixed(1))
        }
      }
      return {
        ...keys,
        units: { bodyMass: 'kg', height: 'm', bodyFatPercentage: 'fraction', leanBodyMass: 'kg', waistCircumference: 'cm' },
        latest: Object.fromEntries(Object.entries(series).map(([type, points]) => [type, points.at(-1) ?? null])),
        days: [...byDate.values()].sort((a, b) => String(a.date).localeCompare(String(b.date))),
      }
    },
  },
  {
    name: 'get_workout_detail',
    title: 'Workout detail',
    description:
      'One workout with its raw heart rate and speed series, covering the session plus a recovery tail after it ends. Use for heart-rate drift, time in heart-rate zones, how fast heart rate drops after stopping, and split or interval pacing. Get the id from get_workouts.',
    inputSchema: {
      type: 'object',
      properties: {
        workoutId: { type: 'string', description: 'Workout id from get_workouts.' },
        recoveryMinutes: { type: 'number', description: 'Minutes of samples to include after the workout ends (default 10, max 60).' },
      },
      required: ['workoutId'],
    },
    run: async (uid, args) => {
      const id = str(args.workoutId)
      if (!id || !/^[A-Za-z0-9-]{1,64}$/.test(id)) throw new BadRequest('`workoutId` is required — get it from get_workouts')
      const workout = await getWorkout(uid, id)
      if (!workout) throw new BadRequest(`No workout with id ${id}`)

      const recovery = num(args.recoveryMinutes, 10, 60)
      const from = new Date(String(workout.startDate))
      const to = new Date(new Date(String(workout.endDate)).getTime() + recovery * 60_000)
      const speedMetric = String(workout.activityTypeName) === 'cycling' ? 'cyclingSpeed' : 'runningSpeed'

      const [heartRate, speed] = await Promise.all([
        querySamples(uid, 'heartRate', { from, to }, 2000),
        querySamples(uid, speedMetric, { from, to }, 2000),
      ])
      // Oldest first reads better as a time series than the newest-first default.
      const series = (samples: Record<string, unknown>[]) =>
        samples
          .map((s) => ({ at: s.startDate as string, value: s.value as number }))
          .sort((a, b) => a.at.localeCompare(b.at))

      return {
        workout,
        window: { from: from.toISOString(), to: to.toISOString(), recoveryMinutes: recovery },
        heartRate: { unit: 'count/min', count: heartRate.length, truncated: heartRate.length >= 2000, series: series(heartRate) },
        speed: { type: speedMetric, unit: 'm/s', count: speed.length, truncated: speed.length >= 2000, series: series(speed) },
      }
    },
  },
  {
    name: 'get_cardio_fitness',
    title: 'Cardio fitness',
    description:
      'VO2 max (what Apple shows as Cardio Fitness) over time with its trend, alongside resting heart rate, HRV and heart rate recovery. Includes a low/below average/above average/high level when the profile has date of birth and biological sex.',
    inputSchema: { type: 'object', properties: { ...dayRange } },
    run: async (uid, args) => {
      const profile = await getProfile(uid)
      const keys = parseDateKeys(str(args.from), str(args.to), 180, String(profile.timeZone ?? 'UTC'))
      const series = await dailySeries(uid, keys.from, keys.to, CARDIO_METRICS)
      const vo2 = (series.vo2Max ?? []) as DocumentDataLike[]
      const current = vo2.at(-1)?.avg as number | undefined
      const age = ageFrom(profile.dateOfBirth)

      return {
        ...keys,
        vo2Max: {
          unit: 'mL/kg/min',
          current: current ?? null,
          at: vo2.at(-1)?.date ?? null,
          trend: summarize(vo2),
          classification: current === undefined ? null : classifyVo2(current, age, profile.biologicalSex),
          series: vo2.map((p) => ({ date: p.date, value: p.avg })),
        },
        age: age ?? null,
        biologicalSex: profile.biologicalSex ?? null,
        supporting: Object.fromEntries(
          CARDIO_METRICS.filter((m) => m !== 'vo2Max').map((m) => [m, summarize((series[m] ?? []) as DocumentDataLike[])]),
        ),
      }
    },
  },
]

// ---------- JSON-RPC ----------

interface RpcRequest {
  jsonrpc: '2.0'
  id?: string | number | null
  method: string
  params?: Json
}

const ok = (id: RpcRequest['id'], result: unknown) => ({ jsonrpc: '2.0', id, result })
const fail = (id: RpcRequest['id'], code: number, message: string) => ({ jsonrpc: '2.0', id: id ?? null, error: { code, message } })

async function callTool(uid: string, params: Json | undefined) {
  const tool = tools.find((t) => t.name === params?.name)
  if (!tool) return null
  try {
    const result = await tool.run(uid, (params?.arguments as Args) ?? {})
    return { content: [{ type: 'text', text: JSON.stringify(result, null, 2) }] }
  } catch (error) {
    // Tool errors are returned as results so the model can see and correct them.
    const message = error instanceof Error ? error.message : String(error)
    if (!(error instanceof BadRequest)) console.error('[mcp] tool failed', tool.name, error)
    return { content: [{ type: 'text', text: `Error: ${message}` }], isError: true }
  }
}

async function dispatch(uid: string, msg: RpcRequest) {
  const { id, method, params } = msg
  switch (method) {
    case 'initialize': {
      const requested = String(params?.protocolVersion ?? '')
      return ok(id, {
        protocolVersion: SUPPORTED_VERSIONS.includes(requested) ? requested : SUPPORTED_VERSIONS[0],
        capabilities: { tools: { listChanged: false } },
        serverInfo: SERVER_INFO,
        instructions: INSTRUCTIONS,
      })
    }
    case 'ping':
      return ok(id, {})
    case 'tools/list':
      return ok(id, { tools: tools.map(({ run, ...t }) => ({ ...t, annotations: { readOnlyHint: true, openWorldHint: false } })) })
    case 'tools/call': {
      const result = await callTool(uid, params)
      return result ? ok(id, result) : fail(id, -32602, `Unknown tool: ${String(params?.name)}`)
    }
    default:
      return fail(id, -32601, `Method not found: ${method}`)
  }
}

// Returns the JSON-RPC response body, or null when the payload held only notifications/responses (HTTP 202).
export async function handleMcp(uid: string, payload: unknown): Promise<unknown | null> {
  const messages = Array.isArray(payload) ? payload : [payload]
  const responses = []
  for (const raw of messages) {
    const msg = raw as RpcRequest
    if (!msg || typeof msg !== 'object' || msg.jsonrpc !== '2.0') {
      responses.push(fail(null, -32600, 'Invalid Request'))
      continue
    }
    if (typeof msg.method !== 'string' || msg.id === undefined) continue // notification or client response
    responses.push(await dispatch(uid, msg))
  }
  if (responses.length === 0) return null
  return Array.isArray(payload) ? responses : responses[0]
}
