// Heart-rate zones.
//
// Every pace and effort cap a coach gives rests on a maximum heart rate. Guessing it from age
// alone is out by ten beats or more in either direction, and the guess gets re-made from scratch
// in every conversation. The watch has been recording a maximum on every workout, so the
// measured figure is reported with the date it was set, and the age formula only stands in when
// there is nothing measured to use.

import { catalog } from './catalog'

const config = catalog.heartRate

export interface ZoneInputs {
  /** Highest heart rates recorded in workouts, highest first, with when each happened. */
  observed?: { value: number; at?: string }[]
  restingHeartRate?: number
  age?: number
}

/**
 * The highest reading that a second one stands near. Wrist sensors occasionally lock onto
 * cadence and report a rate that was never reached; taking the single highest would then move
 * every zone boundary. A peak the next-highest reading corroborates is a peak that happened.
 */
const CORROBORATION_BPM = 6

export function corroboratedMax(observed: { value: number; at?: string }[]) {
  const sorted = [...observed].sort((a, b) => b.value - a.value)
  const [highest, second] = sorted
  if (!highest) return undefined
  if (!second) return highest
  return highest.value - second.value <= CORROBORATION_BPM ? highest : second
}

/** Tanaka rather than 220 − age, which overestimates for adults under forty. */
export const estimatedMaxFor = (age: number) => Math.round(208 - 0.7 * age)

export function heartRateZones(inputs: ZoneInputs) {
  const estimated = inputs.age !== undefined ? estimatedMaxFor(inputs.age) : undefined
  const observed = inputs.observed ?? []
  const measured = observed.length >= config.minWorkoutsForMax ? corroboratedMax(observed) : undefined

  const max = measured?.value ?? estimated
  if (max === undefined) {
    return { max: null, source: null, zones: [], note: 'ไม่มีทั้งชีพจรสูงสุดที่วัดได้และวันเกิด จึงคำนวณโซนไม่ได้' }
  }

  // Karvonen: a zone is a share of the range between resting and maximum, not of the maximum,
  // so two people with the same maximum but different resting pulses get different zones.
  const resting = inputs.restingHeartRate
  const reserve = resting !== undefined ? max - resting : undefined
  const bound = (fraction: number) =>
    Math.round(reserve !== undefined && resting !== undefined ? resting + reserve * fraction : max * fraction)

  return {
    max,
    source: measured ? ('measured' as const) : ('estimated' as const),
    measuredAt: measured?.at,
    workoutsConsidered: observed.length,
    estimatedFromAge: estimated ?? null,
    restingHeartRate: resting ?? null,
    method: resting !== undefined ? ('heart rate reserve (Karvonen)' as const) : ('percent of maximum' as const),
    zones: config.zones.map((z) => ({ ...z, from: bound(z.from), to: bound(z.to) })),
    note: measured
      ? 'ชีพจรสูงสุดมาจากค่าที่วัดได้จริงในการออกกำลังกาย ไม่ใช่สูตรอายุ'
      : `ยังไม่มีการออกกำลังกายที่วัดชีพจรสูงสุดได้ถึง ${config.minWorkoutsForMax} ครั้ง จึงใช้สูตรอายุไปก่อน ค่าจริงมักต่างจากสูตรได้ถึง ±10 ครั้ง/นาที`,
  }
}
