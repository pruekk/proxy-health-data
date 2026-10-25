import { describe, expect, test } from 'bun:test'
import { compareWithUsual, computeBattery } from './battery'

const restingHeartRate = 60
const quiet = (hour: number) => ({ hour, activeEnergyKcal: 5, heartRate: 62 })
const desk = (hour: number) => ({ hour, activeEnergyKcal: 20, heartRate: 78 })

describe('charging', () => {
  test('a full night returns the configured charge', () => {
    const result = computeBattery({ carriedOver: 20, sleepMinutes: 480, restingHeartRate, hours: [] })
    expect(result.chargedOvernight).toBe(55)
    expect(result.level).toBe(75)
  })

  test('a short night returns proportionally less', () => {
    const result = computeBattery({ carriedOver: 20, sleepMinutes: 240, restingHeartRate, hours: [] })
    expect(result.chargedOvernight).toBe(28)
  })

  test('sleeping longer than the target does not overcharge', () => {
    const long = computeBattery({ carriedOver: 20, sleepMinutes: 700, restingHeartRate, hours: [] })
    const exact = computeBattery({ carriedOver: 20, sleepMinutes: 480, restingHeartRate, hours: [] })
    expect(long.chargedOvernight).toBe(exact.chargedOvernight)
  })

  test('never exceeds 100', () => {
    const result = computeBattery({ carriedOver: 95, sleepMinutes: 480, restingHeartRate, hours: [] })
    expect(result.level).toBe(100)
  })
})

describe('draining', () => {
  test('a desk hour costs more than a quiet one', () => {
    const idle = computeBattery({ carriedOver: 80, sleepMinutes: 480, restingHeartRate, hours: [quiet(9)] })
    const working = computeBattery({ carriedOver: 80, sleepMinutes: 480, restingHeartRate, hours: [desk(9)] })
    expect(working.level).toBeLessThan(idle.level)
  })

  test('an hour of hard running costs a visible chunk', () => {
    const result = computeBattery({
      carriedOver: 50,
      sleepMinutes: 480,
      restingHeartRate,
      hours: [{ hour: 6, activeEnergyKcal: 600, heartRate: 150 }],
    })
    // 600 kcal / 20 = 30, plus 2 idle, plus (150-60-15)/10 = 7.5
    expect(result.drainedToday).toBe(40)
  })

  test('a genuinely restful hour gives a little back', () => {
    // Starting below the ceiling: a full night from 50 already pins the battery at 100.
    const result = computeBattery({
      carriedOver: 20,
      sleepMinutes: 480,
      restingHeartRate,
      hours: [{ hour: 14, activeEnergyKcal: 0, heartRate: 61 }],
    })
    expect(result.level).toBeGreaterThan(result.afterSleep)
  })

  test('never drops below zero', () => {
    const hours = Array.from({ length: 16 }, (_, i) => ({ hour: i, activeEnergyKcal: 900, heartRate: 170 }))
    const result = computeBattery({ carriedOver: 10, sleepMinutes: 120, restingHeartRate, hours })
    expect(result.level).toBe(0)
  })

  test('steps report the level after each hour', () => {
    const result = computeBattery({
      carriedOver: 50,
      sleepMinutes: 480,
      restingHeartRate,
      hours: [desk(9), desk(10)],
    })
    expect(result.steps).toHaveLength(2)
    expect(result.steps[1]!.level).toBeLessThan(result.steps[0]!.level)
  })
})

describe('missing data', () => {
  test('names what it did not have', () => {
    const result = computeBattery({ hours: [] })
    expect(result.missing).toEqual(['sleep', 'restingHeartRate', 'hourly'])
  })

  test('still produces a level from the carry-over alone', () => {
    const result = computeBattery({ carriedOver: 40, hours: [] })
    expect(result.level).toBe(40)
  })

  test('an hour without a heart rate only costs activity and idle', () => {
    const result = computeBattery({
      carriedOver: 60,
      sleepMinutes: 480,
      restingHeartRate,
      hours: [{ hour: 9, activeEnergyKcal: 40 }],
    })
    expect(result.drainedToday).toBe(4)
  })
})

describe('comparison with a usual day', () => {
  test('reports the direction and size', () => {
    expect(compareWithUsual(68, 62)?.text).toBe('สูงกว่าปกติของเวลานี้ 6%')
    expect(compareWithUsual(55, 70)?.text).toBe('ต่ำกว่าปกติของเวลานี้ 15%')
  })

  test('says so when they match', () => {
    expect(compareWithUsual(68, 68)?.text).toBe('เท่ากับปกติของเวลานี้')
  })

  test('nothing to compare against returns null', () => {
    expect(compareWithUsual(68)).toBeNull()
  })
})

describe('the coaching line', () => {
  const at = (level: number, usual?: number) =>
    computeBattery({ carriedOver: level, sleepMinutes: 0, restingHeartRate: 50, hours: [], usualAtThisHour: usual })

  test('changes band with the level', () => {
    expect(at(80).advice).toBe('ยังเหลือพอสำหรับซ้อมหนัก')
    expect(at(50).advice).toBe('ยังมีพอสำหรับซ้อมเบาถึงปานกลาง')
    expect(at(25).advice).toBe('เหลือไม่มาก เน้นงานเบาและพักให้พอ')
    expect(at(10).advice).toBe('ใกล้หมด ควรพักและนอนให้เร็วขึ้น')
  })

  test('leads with the comparison when there is history', () => {
    expect(at(68, 62).message).toBe('สูงกว่าปกติของเวลานี้ 6% — ยังมีพอสำหรับซ้อมเบาถึงปานกลาง')
  })

  test('is the advice alone without history', () => {
    expect(at(68).message).toBe('ยังมีพอสำหรับซ้อมเบาถึงปานกลาง')
    expect(at(68).comparison).toBeNull()
  })
})
