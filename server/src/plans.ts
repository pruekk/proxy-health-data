// Training plans: what the coach intends for a day, kept beside what actually happened.
//
// The rule that shapes everything here is that the past is a record, not a draft. A plan for a
// day that has been and gone cannot be written or rewritten — otherwise the only interesting
// question, "did what I intended match what I did", answers itself every time.

import { catalog } from './catalog'

/** The vocabulary the user's own coaching material uses, rather than a parallel set. */
export const PLAN_TYPES = ['easy', 'marathon', 'threshold', 'interval', 'repetition', 'long', 'cross', 'rest'] as const
export type PlanType = (typeof PLAN_TYPES)[number]

export const PHASES = ['warmup', 'main', 'recovery', 'cooldown', 'stretch', 'drill', 'plyometrics'] as const
export type Phase = (typeof PHASES)[number]

export interface PlanStep {
  phase: Phase
  minutes?: number
  distanceKm?: number
  /** Target pace as [fastest, slowest] seconds per kilometre — a range, since a single number
   *  is a promise nobody can keep in the heat. */
  paceSecPerKm?: [number, number]
  zone?: number
  detail?: string
}

export interface PlanDay {
  date: string
  type: PlanType
  totalMinutes?: number
  targetDistanceKm?: number
  steps?: PlanStep[]
  /** Interval and repetition sessions: how many times through, and how long each way. */
  reps?: { count: number; workMinutes?: number; workDistanceKm?: number; restMinutes?: number }
  note?: string
}

/** Sessions that mean "go for a run"; everything else is its own thing. */
const RUNNING_TYPES = new Set<PlanType>(['easy', 'marathon', 'threshold', 'interval', 'repetition', 'long'])

export const isRunning = (type: PlanType) => RUNNING_TYPES.has(type)

export class PlanRejected extends Error {}

/**
 * Checks one day and returns it cleaned up, or throws with the reason. Days are validated one at
 * a time so a batch can report per day instead of failing as a block.
 *
 * @param today      the user's local date
 * @param hasWorkout whether that day already has a recorded workout
 */
export function validateDay(day: unknown, today: string, hasWorkout: boolean): PlanDay {
  const input = (day ?? {}) as Record<string, unknown>
  const date = String(input.date ?? '')
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) throw new PlanRejected('`date` ต้องเป็น YYYY-MM-DD')

  if (date < today) throw new PlanRejected(`ไม่แก้แผนย้อนหลัง — ${date} ผ่านไปแล้ว`)
  if (date === today && hasWorkout) {
    throw new PlanRejected(`วันนี้ออกกำลังกายไปแล้ว แผนของ ${date} จึงปิด`)
  }
  const horizon = catalog.plan.maxDaysAhead
  if (daysBetween(today, date) > horizon) {
    throw new PlanRejected(`วางแผนล่วงหน้าได้ไม่เกิน ${horizon} วัน`)
  }

  const type = String(input.type ?? '') as PlanType
  if (!PLAN_TYPES.includes(type)) {
    throw new PlanRejected(`\`type\` ต้องเป็นหนึ่งใน ${PLAN_TYPES.join(', ')}`)
  }

  const steps = Array.isArray(input.steps) ? input.steps.map((s) => validateStep(s)) : undefined
  const cleaned: PlanDay = { date, type }
  if (typeof input.totalMinutes === 'number') cleaned.totalMinutes = input.totalMinutes
  if (typeof input.targetDistanceKm === 'number') cleaned.targetDistanceKm = input.targetDistanceKm
  if (steps?.length) cleaned.steps = steps
  if (typeof input.note === 'string') cleaned.note = input.note
  const reps = input.reps as PlanDay['reps']
  if (reps && typeof reps.count === 'number' && reps.count > 0) cleaned.reps = reps
  return cleaned
}

function validateStep(step: unknown): PlanStep {
  const input = (step ?? {}) as Record<string, unknown>
  const phase = String(input.phase ?? '') as Phase
  if (!PHASES.includes(phase)) throw new PlanRejected(`\`phase\` ต้องเป็นหนึ่งใน ${PHASES.join(', ')}`)
  const out: PlanStep = { phase }
  if (typeof input.minutes === 'number') out.minutes = input.minutes
  if (typeof input.distanceKm === 'number') out.distanceKm = input.distanceKm
  if (typeof input.zone === 'number') out.zone = input.zone
  if (typeof input.detail === 'string') out.detail = input.detail
  const pace = input.paceSecPerKm
  if (Array.isArray(pace) && pace.length === 2 && pace.every((v) => typeof v === 'number')) {
    const [fast, slow] = pace as [number, number]
    out.paceSecPerKm = fast <= slow ? [fast, slow] : [slow, fast]
  }
  return out
}

export type Outcome = 'planned' | 'done' | 'different' | 'missed' | 'rest' | 'unplanned' | 'none'

export interface DayActual {
  /** HealthKit's own name, e.g. `running`. */
  activityTypeName?: string
  avgHeartRate?: number
  paceSecPerKm?: number
}

/**
 * What became of a day.
 *
 * Deliberately matches on what kind of activity happened, not on how hard it was: the watch
 * records that a run took place, never that it was meant to be the easy one. A run that was
 * supposed to be gentle and came out at threshold is still `done` — and flagged `harder`, which
 * is the honest way to say it.
 */
export function outcomeFor(args: {
  date: string
  today: string
  plan?: { type: PlanType }
  actuals: DayActual[]
}): { outcome: Outcome; harder?: boolean } {
  const { date, today, plan, actuals } = args
  const didSomething = actuals.length > 0

  if (!plan) {
    if (didSomething) return { outcome: 'unplanned' }
    return { outcome: date > today ? 'planned' : 'none' }
  }
  if (date > today) return { outcome: 'planned' }

  if (plan.type === 'rest') return { outcome: didSomething ? 'different' : 'rest' }
  if (!didSomething) return { outcome: date === today ? 'planned' : 'missed' }

  const ranSomething = actuals.some((a) => String(a.activityTypeName ?? '').toLowerCase().includes('running'))
  const matches = isRunning(plan.type) ? ranSomething : !ranSomething
  return { outcome: matches ? 'done' : 'different' }
}

/** Whether the session went harder than it was written to be. */
export function wentHarder(plan: PlanDay | undefined, actuals: DayActual[], zoneCeiling?: number) {
  if (!plan?.steps?.length || !actuals.length) return false
  const targetZone = Math.max(...plan.steps.map((s) => s.zone ?? 0))
  const targetPace = plan.steps.map((s) => s.paceSecPerKm?.[0]).filter((v): v is number => typeof v === 'number')

  for (const actual of actuals) {
    // Faster than the quick end of the target range, by more than a rounding error.
    if (targetPace.length && actual.paceSecPerKm && actual.paceSecPerKm < Math.min(...targetPace) - 5) return true
    // Or spent above the zone it was written for.
    if (targetZone && zoneCeiling && actual.avgHeartRate && actual.avgHeartRate > zoneCeiling) return true
  }
  return false
}

const DAY_MS = 86_400_000
export const daysBetween = (from: string, to: string) =>
  Math.round((new Date(`${to}T00:00:00Z`).getTime() - new Date(`${from}T00:00:00Z`).getTime()) / DAY_MS)
