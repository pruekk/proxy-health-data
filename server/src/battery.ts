// Body battery: how much is left right now, as opposed to readiness, which is how recovered the
// morning started. The level climbs through the night at a fixed rate per hour actually asleep,
// starting from wherever the evening left it, then drains with activity and an elevated heart
// rate through the day. It carries over: one good night does not refill a week of deficit.
//
// Garmin and Bevel run this on beat-to-beat HRV through the whole day (Firstbeat). Apple Watch
// does not expose that, so heart rate against resting plus the energy actually burned stands in.
// The numbers are calibrated against the reference device for the same night, not derived from
// the same signal.

import { catalog } from './catalog'

export interface BatteryHour {
  /** Local hour, 0-23. */
  hour: number
  activeEnergyKcal?: number
  heartRate?: number
}

/** Daytime sleep. Charges at the night rate but capped, so a nap cannot stand in for a night. */
export interface BatteryNap {
  hour: number
  asleepMinutes: number
}

export interface BatteryDay {
  /** Local date, for reporting only. */
  date: string
  /** Minutes asleep in the night that ended this morning. Absent means the watch was off. */
  asleepMinutes?: number
  naps?: BatteryNap[]
  /** Hours since waking, oldest first. */
  hours: BatteryHour[]
  restingHeartRate?: number
  /** True when `asleepMinutes` is a stand-in rather than a measurement. */
  sleepEstimated?: boolean
}

/** One stretch of sleep, already expressed in the user's local date and the hour it ended. */
export interface SleepSession {
  date: string
  hour: number
  asleepMinutes: number
}

/**
 * Sorts sleep into the night and the naps around it.
 *
 * Everything ending before midday counts towards the night and is added up, because a night
 * broken by an hour awake arrives as two sessions and treating the second as a nap would both
 * lose sleep and charge what is left at the capped nap rate. A long stretch that ends later
 * still counts as a night — someone who works nights, or sleeps until two, has had a night —
 * but it does not set the waking hour, since the day's drain has been running all along.
 */
export function groupSleep(sessions: SleepSession[], nightEndsBeforeHour = 12, nightMinutes = 150) {
  const nights = new Map<string, number>()
  const wokeAt = new Map<string, number>()
  const naps = new Map<string, BatteryNap[]>()

  for (const session of sessions) {
    const inTheMorning = session.hour < nightEndsBeforeHour
    if (inTheMorning || session.asleepMinutes >= nightMinutes) {
      nights.set(session.date, (nights.get(session.date) ?? 0) + session.asleepMinutes)
      if (inTheMorning) wokeAt.set(session.date, Math.max(wokeAt.get(session.date) ?? 0, session.hour))
      continue
    }
    const list = naps.get(session.date) ?? []
    list.push({ hour: session.hour, asleepMinutes: session.asleepMinutes })
    naps.set(session.date, list)
  }
  return { nights, wokeAt, naps }
}

export interface BatteryStep {
  hour: number
  level: number
  change: number
}

const config = catalog.battery
const clamp = (value: number) => Math.max(config.min, Math.min(config.max, value))
const round = (value: number) => Math.round(value * 10) / 10

interface DayResult {
  date: string
  wakeLevel: number
  bedLevel: number
  level: number
  chargedOvernight: number
  napCharge: number
  restCharge: number
  drained: number
  steps: BatteryStep[]
  /** Level at the end of each hour, for "what is usual at this hour". */
  byHour: Map<number, number>
}

/** One day: charge for the night that ended this morning, then walk the waking hours. */
function runDay(day: BatteryDay, startLevel: number): DayResult {
  const bedLevel = startLevel
  const chargedOvernight = ((day.asleepMinutes ?? 0) / 60) * config.chargePerSleepHour
  let level = clamp(startLevel + chargedOvernight)
  const wakeLevel = level

  const napByHour = new Map<number, number>()
  let napBudget = config.napDailyMaxCharge
  for (const nap of day.naps ?? []) {
    if (nap.asleepMinutes < config.napMinMinutes) continue
    const charge = Math.min((nap.asleepMinutes / 60) * config.chargePerSleepHour, config.napMaxCharge, napBudget)
    if (charge <= 0) continue
    napBudget -= charge
    napByHour.set(nap.hour, (napByHour.get(nap.hour) ?? 0) + charge)
  }

  const steps: BatteryStep[] = []
  const byHour = new Map<number, number>()
  let drained = 0
  let napCharge = 0
  let restCharge = 0

  for (const hour of day.hours) {
    const before = level
    const nap = napByHour.get(hour.hour) ?? 0

    let change: number
    if (nap > 0) {
      // Asleep for part of the hour: it charges rather than drains.
      change = nap
      napCharge += nap
    } else {
      const activityDrain = (hour.activeEnergyKcal ?? 0) / config.activeEnergyDivisor

      // Heart rate above resting costs on top of the energy, which is what separates a
      // stressful hour at a desk from a calm one.
      let stressDrain = 0
      if (hour.heartRate !== undefined && day.restingHeartRate !== undefined) {
        const excess = hour.heartRate - day.restingHeartRate - config.hrStressOffset
        if (excess > 0) stressDrain = excess / config.hrStressDivisor
      }

      // A quiet hour gives a little back instead of only ever draining.
      const resting =
        activityDrain < 0.5 &&
        stressDrain === 0 &&
        hour.heartRate !== undefined &&
        day.restingHeartRate !== undefined &&
        hour.heartRate <= day.restingHeartRate + 5

      change = resting ? config.restChargePerHour : -(config.idleDrainPerHour + activityDrain + stressDrain)
      if (resting) restCharge += config.restChargePerHour
    }

    level = clamp(before + change)
    drained += Math.max(0, before - level)
    steps.push({ hour: hour.hour, level: round(level), change: round(level - before) })
    byHour.set(hour.hour, round(level))
  }

  return {
    date: day.date,
    wakeLevel: Math.round(wakeLevel),
    bedLevel: Math.round(bedLevel),
    level: Math.round(level),
    chargedOvernight: Math.round(chargedOvernight),
    napCharge: Math.round(napCharge),
    restCharge: Math.round(restCharge),
    drained: Math.round(drained),
    steps,
    byHour,
  }
}

export interface BatteryInputs {
  /** Oldest first, today last. Each day's level starts where the previous one ended. */
  days: BatteryDay[]
  /** Local hour now, for the "usual at this hour" comparison. */
  hourNow?: number
  /** Where the chain starts, before the first day in the list. */
  seedLevel?: number
}

export function computeBattery(inputs: BatteryInputs) {
  const days = inputs.days
  const today = days[days.length - 1]
  const missing: string[] = []
  if (!today) {
    return {
      level: null,
      missing: ['hourly', 'sleep'],
      estimated: true,
      basis: BASIS,
    }
  }
  if (today.asleepMinutes === undefined) missing.push('sleep')
  if (today.restingHeartRate === undefined) missing.push('restingHeartRate')
  if (!today.hours.length) missing.push('hourly')

  let level = inputs.seedLevel ?? config.seedLevel
  const results: DayResult[] = []
  for (const day of days) {
    const result = runDay(day, level)
    results.push(result)
    level = result.level
  }

  const result = results[results.length - 1]!
  // Same simulation on the days before today, read at the hour it is now, so the comparison is
  // like-for-like instead of against a whole-day average.
  const usual = usualAtHour(results.slice(0, -1), inputs.hourNow)
  const comparison = compareWithUsual(result.level, usual)
  const advice = adviceFor(result.level)
  // Anything the level rests on that was not measured: a stood-in night, no night at all, or a
  // day with no hourly data to drain against.
  const estimated = Boolean(today.sleepEstimated) || today.asleepMinutes === undefined || !today.hours.length

  return {
    level: result.level,
    /** Where the day started, after the night's charge. */
    wakeLevel: result.wakeLevel,
    /** Where it stood when that night began — the carry-over made visible. */
    bedLevel: result.bedLevel,
    chargedOvernight: result.chargedOvernight,
    /** Old name for `wakeLevel`, kept so the build already on the phone keeps decoding the
     *  response until it is replaced. */
    afterSleep: result.wakeLevel,
    napCharge: result.napCharge,
    /** Signed: negative is the usual case, positive means a nap or a very quiet day. */
    sinceWake: result.level - result.wakeLevel,
    drainedToday: result.drained,
    steps: result.steps,
    missing,
    /** True when any part of this rests on a stand-in rather than a measurement. */
    estimated,
    comparison,
    advice,
    message: comparison ? `${comparison.text} — ${advice}` : advice,
    basis: BASIS,
  }
}

const BASIS = 'ประมาณจากชีพจรเทียบค่าพักและแคลอรีที่เผา ไม่ใช่ HRV ต่อจังหวะแบบ Garmin'

function usualAtHour(past: DayResult[], hourNow?: number) {
  if (hourNow === undefined) return undefined
  const levels = past.map((day) => day.byHour.get(hourNow)).filter((v): v is number => v !== undefined)
  if (!levels.length) return undefined
  return levels.reduce((sum, value) => sum + value, 0) / levels.length
}

/** How today compares with the same hour on other days, for the coaching line. */
export function compareWithUsual(level: number, usualAtThisHour?: number) {
  if (usualAtThisHour === undefined) return null
  const delta = Math.round(level - usualAtThisHour)
  if (delta === 0) return { delta, text: 'เท่ากับปกติของเวลานี้' }
  return { delta, text: `${delta > 0 ? 'สูง' : 'ต่ำ'}กว่าปกติของเวลานี้ ${Math.abs(delta)}%` }
}

/** What the remaining level means for the rest of the day. Fixed bands, so the sentence only
 *  changes when the number does. */
function adviceFor(level: number) {
  if (level >= 70) return 'ยังเหลือพอสำหรับซ้อมหนัก'
  if (level >= 40) return 'ยังมีพอสำหรับซ้อมเบาถึงปานกลาง'
  if (level >= 20) return 'เหลือไม่มาก เน้นงานเบาและพักให้พอ'
  return 'ใกล้หมด ควรพักและนอนให้เร็วขึ้น'
}
