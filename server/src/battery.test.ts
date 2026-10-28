import { describe, expect, test } from 'bun:test'
import { compareWithUsual, computeBattery, groupSleep, type BatteryDay } from './battery'

const RHR = 55
const day = (over: Partial<BatteryDay> = {}): BatteryDay => ({
  date: '2026-10-28',
  asleepMinutes: 480,
  hours: [],
  restingHeartRate: RHR,
  ...over,
})

const run = (days: BatteryDay[], seedLevel = 50, hourNow?: number) =>
  computeBattery({ days, seedLevel, hourNow })

describe('charging through the night', () => {
  test('climbs from where the evening left it', () => {
    // The reference device: 40% at bedtime, 6h19 asleep, 78% on waking.
    const result = run([day({ asleepMinutes: 379 })], 40)
    expect(result.bedLevel).toBe(40)
    expect(result.wakeLevel).toBe(78)
  })

  test('a full night is worth 48 points', () => {
    expect(run([day({ asleepMinutes: 480 })], 30).wakeLevel).toBe(78)
  })

  test('half a night is worth half as much', () => {
    expect(run([day({ asleepMinutes: 240 })], 30).wakeLevel).toBe(54)
  })

  test('cannot charge past full', () => {
    expect(run([day({ asleepMinutes: 600 })], 80).wakeLevel).toBe(100)
  })

  test('a missing night charges nothing', () => {
    const result = run([day({ asleepMinutes: undefined })], 40)
    expect(result.wakeLevel).toBe(40)
    expect(result.missing).toContain('sleep')
  })
})

describe('draining through the day', () => {
  test('an idle hour costs one point', () => {
    const result = run([day({ asleepMinutes: 0, hours: [{ hour: 9, activeEnergyKcal: 0, heartRate: 70 }] })], 60)
    expect(result.level).toBe(59)
  })

  test('a 600 kcal run costs twenty plus the stress of a high pulse', () => {
    const result = run([day({ asleepMinutes: 0, hours: [{ hour: 6, activeEnergyKcal: 600, heartRate: 150 }] })], 90)
    // 1 idle + 600/30 + (150 - 55 - 15)/14 = 1 + 20 + 5.7
    expect(result.level).toBe(63)
    expect(result.drainedToday).toBe(27)
  })

  test('a restful hour gives a little back', () => {
    const result = run([day({ asleepMinutes: 0, hours: [{ hour: 14, activeEnergyKcal: 2, heartRate: 56 }] })], 50)
    expect(result.level).toBe(52)
  })

  test('cannot drain below empty', () => {
    const hours = Array.from({ length: 12 }, (_, i) => ({ hour: i + 8, activeEnergyKcal: 400, heartRate: 140 }))
    expect(run([day({ asleepMinutes: 0, hours })], 40).level).toBe(0)
  })

  test('an hour without a heart rate only costs activity and idle', () => {
    const result = run([day({ asleepMinutes: 0, hours: [{ hour: 9, activeEnergyKcal: 60 }] })], 60)
    expect(result.level).toBe(57)
  })

  test('sinceWake carries the sign', () => {
    const result = run([day({ asleepMinutes: 0, hours: [{ hour: 9, activeEnergyKcal: 60 }] })], 60)
    expect(result.sinceWake).toBe(-3)
  })
})

describe('naps', () => {
  const napDay = (minutes: number) =>
    day({
      asleepMinutes: 0,
      naps: [{ hour: 14, asleepMinutes: minutes }],
      hours: [{ hour: 14, activeEnergyKcal: 0, heartRate: 60 }],
    })

  test('charge at the night rate', () => {
    const result = run([napDay(60)], 50)
    expect(result.napCharge).toBe(6)
    expect(result.level).toBe(56)
  })

  test('are capped, so one cannot stand in for a night', () => {
    expect(run([napDay(300)], 50).napCharge).toBe(15)
  })

  test('a doze too short to matter is not charged as a nap', () => {
    const result = run([napDay(10)], 50)
    expect(result.napCharge).toBe(0)
    // It falls back to the ordinary rule for a quiet hour, which is worth less.
    expect(result.level).toBe(52)
  })

  test('the day has a ceiling across all naps', () => {
    const result = run([
      day({
        asleepMinutes: 0,
        naps: [
          { hour: 11, asleepMinutes: 180 },
          { hour: 15, asleepMinutes: 180 },
        ],
        hours: [
          { hour: 11, heartRate: 60 },
          { hour: 15, heartRate: 60 },
        ],
      }),
    ], 50)
    expect(result.napCharge).toBe(20)
  })
})

describe('carrying over between days', () => {
  test('a deficit is not wiped out by one good night', () => {
    const hard = day({ date: 'd1', asleepMinutes: 300, hours: Array.from({ length: 14 }, (_, i) => ({ hour: i + 7, activeEnergyKcal: 300, heartRate: 120 })) })
    const rest = day({ date: 'd2', asleepMinutes: 480, hours: [] })
    const result = run([hard, rest], 60)
    expect(result.bedLevel).toBeLessThan(20)
    expect(result.wakeLevel).toBeLessThan(70)
  })

  test('two quiet nights climb towards full', () => {
    const quiet = (date: string) => day({ date, asleepMinutes: 450, hours: [] })
    expect(run([quiet('d1'), quiet('d2')], 20).wakeLevel).toBe(100)
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

  test('comes from the same hour on earlier days', () => {
    const past = day({ date: 'd1', asleepMinutes: 480, hours: [{ hour: 9, activeEnergyKcal: 30, heartRate: 80 }] })
    const today = day({ date: 'd2', asleepMinutes: 480, hours: [{ hour: 9, activeEnergyKcal: 900, heartRate: 150 }] })
    const result = run([past, today], 40, 9)
    expect(result.comparison?.delta).toBeLessThan(0)
    expect(result.message).toContain('ต่ำกว่าปกติของเวลานี้')
  })
})

describe('the coaching line', () => {
  const at = (level: number, hours: BatteryDay['hours'] = []) =>
    computeBattery({ days: [day({ asleepMinutes: 0, hours })], seedLevel: level })

  test('changes band with the level', () => {
    expect(at(80).advice).toBe('ยังเหลือพอสำหรับซ้อมหนัก')
    expect(at(50).advice).toBe('ยังมีพอสำหรับซ้อมเบาถึงปานกลาง')
    expect(at(25).advice).toBe('เหลือไม่มาก เน้นงานเบาและพักให้พอ')
    expect(at(10).advice).toBe('ใกล้หมด ควรพักและนอนให้เร็วขึ้น')
  })

  test('is the advice alone without history', () => {
    expect(at(68).message).toBe('ยังมีพอสำหรับซ้อมเบาถึงปานกลาง')
    expect(at(68).comparison).toBeNull()
  })
})

describe('estimates are flagged', () => {
  test('a stand-in night marks the day', () => {
    const result = run([day({ asleepMinutes: 400, sleepEstimated: true, hours: [{ hour: 9, heartRate: 70 }] })], 40)
    expect(result.estimated).toBe(true)
  })

  test('a measured day is not flagged', () => {
    expect(run([day({ hours: [{ hour: 9, heartRate: 70 }] })], 40).estimated).toBe(false)
  })

  test('a night with no data at all is an estimate', () => {
    expect(run([day({ asleepMinutes: undefined, hours: [{ hour: 9, heartRate: 70 }] })], 40).estimated).toBe(true)
  })

  test('no hourly data at all is an estimate too', () => {
    expect(run([day({ hours: [] })], 40).estimated).toBe(true)
  })
})

describe('sorting sleep into nights and naps', () => {
  test('a night broken by an hour awake is still one night', () => {
    const { nights, wokeAt, naps } = groupSleep([
      { date: '2026-10-28', hour: 2, asleepMinutes: 150 },
      { date: '2026-10-28', hour: 6, asleepMinutes: 180 },
    ])
    expect(nights.get('2026-10-28')).toBe(330)
    expect(wokeAt.get('2026-10-28')).toBe(6)
    expect(naps.get('2026-10-28')).toBeUndefined()
  })

  test('the afternoon is a nap, not part of the night', () => {
    const { nights, naps } = groupSleep([
      { date: '2026-10-28', hour: 6, asleepMinutes: 380 },
      { date: '2026-10-28', hour: 14, asleepMinutes: 50 },
    ])
    expect(nights.get('2026-10-28')).toBe(380)
    expect(naps.get('2026-10-28')).toEqual([{ hour: 14, asleepMinutes: 50 }])
  })

  test('waking is the end of the last stretch before midday', () => {
    const { wokeAt } = groupSleep([
      { date: '2026-10-28', hour: 3, asleepMinutes: 200 },
      { date: '2026-10-28', hour: 8, asleepMinutes: 60 },
    ])
    expect(wokeAt.get('2026-10-28')).toBe(8)
  })

  test('a long sleep that ends in the afternoon is still a night', () => {
    const { nights, naps, wokeAt } = groupSleep([{ date: '2026-10-28', hour: 14, asleepMinutes: 400 }])
    expect(nights.get('2026-10-28')).toBe(400)
    expect(naps.get('2026-10-28')).toBeUndefined()
    // It does not set the waking hour: the day it belongs to has been running since midnight.
    expect(wokeAt.get('2026-10-28')).toBeUndefined()
  })

  test('days are kept apart', () => {
    const { nights } = groupSleep([
      { date: '2026-10-27', hour: 6, asleepMinutes: 400 },
      { date: '2026-10-28', hour: 7, asleepMinutes: 300 },
    ])
    expect(nights.get('2026-10-27')).toBe(400)
    expect(nights.get('2026-10-28')).toBe(300)
  })

  test('nothing recorded leaves every map empty', () => {
    const { nights, naps, wokeAt } = groupSleep([])
    expect(nights.size + naps.size + wokeAt.size).toBe(0)
  })
})
