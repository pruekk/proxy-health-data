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
  /** Highest heart rate recorded in a workout, with when it happened. */
  observedMax?: { value: number; at?: string; workouts: number }
  restingHeartRate?: number
  age?: number
}

/** Tanaka rather than 220 − age, which overestimates for adults under forty. */
export const estimatedMaxFor = (age: number) => Math.round(208 - 0.7 * age)

export function heartRateZones(inputs: ZoneInputs) {
  const estimated = inputs.age !== undefined ? estimatedMaxFor(inputs.age) : undefined
  const measured =
    inputs.observedMax && inputs.observedMax.workouts >= config.minWorkoutsForMax ? inputs.observedMax : undefined

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
    workoutsConsidered: inputs.observedMax?.workouts ?? 0,
    estimatedFromAge: estimated ?? null,
    restingHeartRate: resting ?? null,
    method: resting !== undefined ? ('heart rate reserve (Karvonen)' as const) : ('percent of maximum' as const),
    zones: config.zones.map((z) => ({ ...z, from: bound(z.from), to: bound(z.to) })),
    note: measured
      ? 'ชีพจรสูงสุดมาจากค่าที่วัดได้จริงในการออกกำลังกาย ไม่ใช่สูตรอายุ'
      : `ยังไม่มีการออกกำลังกายที่วัดชีพจรสูงสุดได้ถึง ${config.minWorkoutsForMax} ครั้ง จึงใช้สูตรอายุไปก่อน ค่าจริงมักต่างจากสูตรได้ถึง ±10 ครั้ง/นาที`,
  }
}
