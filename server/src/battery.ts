// Body battery: how much is left right now, as opposed to readiness, which is how recovered you
// were this morning. Charges with sleep and rest, drains with activity and an elevated heart
// rate, and carries over rather than resetting at midnight.
//
// Garmin's version runs on beat-to-beat HRV through the whole day (Firstbeat). Apple Watch does
// not expose that, so heart rate against resting plus the energy actually burned stands in. The
// numbers will not match Garmin's and are not meant to.

import { catalog } from './catalog'

export interface BatteryHour {
  /** Local hour, 0-23. */
  hour: number
  activeEnergyKcal?: number
  heartRate?: number
}

export interface BatteryInputs {
  /** Where the battery stood when the previous day ended. */
  carriedOver?: number
  sleepMinutes?: number
  restingHeartRate?: number
  /** Hours since waking, oldest first. */
  hours: BatteryHour[]
  /** Where the battery usually stands at this hour, from the same simulation run over recent
   *  days. Drives the coaching line; absent until there are a few days of hourly data. */
  usualAtThisHour?: number
}

export interface BatteryStep {
  hour: number
  level: number
  change: number
}

const config = catalog.battery
const clamp = (value: number) => Math.max(config.min, Math.min(config.max, value))
const round = (value: number) => Math.round(value * 10) / 10

export function computeBattery(inputs: BatteryInputs) {
  const missing: string[] = []
  if (inputs.sleepMinutes === undefined) missing.push('sleep')
  if (inputs.restingHeartRate === undefined) missing.push('restingHeartRate')
  if (!inputs.hours.length) missing.push('hourly')

  // Sleep is the only thing that returns a large amount at once.
  const charge =
    inputs.sleepMinutes === undefined
      ? 0
      : (Math.min(inputs.sleepMinutes, config.sleepTargetMinutes) / config.sleepTargetMinutes) * config.sleepChargeFull

  let level = clamp((inputs.carriedOver ?? config.max / 2) + charge)
  const afterSleep = level
  const steps: BatteryStep[] = []
  let drained = 0

  for (const hour of inputs.hours) {
    const energy = hour.activeEnergyKcal ?? 0
    const activityDrain = energy / config.activeEnergyDivisor

    // Heart rate above resting costs on top of the energy, which is what separates a stressful
    // hour at a desk from a calm one.
    let stressDrain = 0
    if (hour.heartRate !== undefined && inputs.restingHeartRate !== undefined) {
      const excess = hour.heartRate - inputs.restingHeartRate - config.hrStressOffset
      if (excess > 0) stressDrain = excess / config.hrStressDivisor
    }

    // A quiet hour gives a little back instead of only ever draining.
    const resting =
      activityDrain < 0.5 &&
      stressDrain === 0 &&
      hour.heartRate !== undefined &&
      inputs.restingHeartRate !== undefined &&
      hour.heartRate <= inputs.restingHeartRate + 5

    const change = resting ? config.restChargePerHour : -(config.idleDrainPerHour + activityDrain + stressDrain)
    const next = clamp(level + change)
    drained += Math.max(0, level - next)
    level = next
    steps.push({ hour: hour.hour, level: round(level), change: round(next - (level - change)) })
  }

  const rounded = Math.round(level)
  const comparison = compareWithUsual(rounded, inputs.usualAtThisHour)
  const advice = adviceFor(rounded)

  return {
    level: rounded,
    chargedOvernight: Math.round(charge),
    drainedToday: Math.round(drained),
    afterSleep: Math.round(afterSleep),
    steps,
    missing,
    comparison,
    advice,
    message: comparison ? `${comparison.text} — ${advice}` : advice,
    basis: 'ประมาณจากชีพจรเทียบค่าพักและแคลอรีที่เผา ไม่ใช่ HRV ต่อจังหวะแบบ Garmin',
  }
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
