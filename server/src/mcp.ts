// Minimal stateless MCP server (Streamable HTTP transport, JSON responses).
// Spec: https://modelcontextprotocol.io/specification — supports initialize, ping, tools/list, tools/call.

import { parseDateKeys, parseRange } from './dates'
import { BadRequest, getProfile, listMetrics, queryDaily, querySamples, querySleep, queryWorkouts } from './store'

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

const tools: Tool[] = [
  {
    name: 'list_metrics',
    title: 'List metrics',
    description:
      'List every HealthKit metric synced for this user (e.g. stepCount, heartRate, restingHeartRate, sleepAnalysis, vo2Max) with its unit, kind and most recent sample. Also returns the profile (time zone, last sync time).',
    inputSchema: { type: 'object', properties: {} },
    run: async (uid) => ({ profile: await getProfile(uid), metrics: await listMetrics(uid) }),
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
        limit: { type: 'number', description: 'Max samples (default 200, max 1000).' },
      },
      required: ['type'],
    },
    run: async (uid, args) => {
      const type = str(args.type)
      if (!type || !/^[A-Za-z0-9_]{1,80}$/.test(type)) throw new BadRequest('`type` is required, e.g. "heartRate"')
      const samples = await querySamples(uid, type, parseRange(str(args.from), str(args.to), 7), num(args.limit, 200, 1000))
      return { type, count: samples.length, samples }
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
