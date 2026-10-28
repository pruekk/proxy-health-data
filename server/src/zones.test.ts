import { describe, expect, test } from 'bun:test'
import { estimatedMaxFor, heartRateZones } from './zones'

const observed = { value: 187, at: '2026-10-21', workouts: 36 }

describe('heart-rate zones', () => {
  test('prefers the heart rate actually recorded', () => {
    const result = heartRateZones({ observedMax: observed, restingHeartRate: 59, age: 28 })
    expect(result.max).toBe(187)
    expect(result.source).toBe('measured')
    expect(result.measuredAt).toBe('2026-10-21')
  })

  test('zones span resting to maximum, not zero to maximum', () => {
    const result = heartRateZones({ observedMax: observed, restingHeartRate: 59, age: 28 })
    // Reserve is 128; zone 2 runs from 60% to 70% of it, above resting.
    expect(result.zones[1]!.from).toBe(136)
    expect(result.zones[1]!.to).toBe(149)
    expect(result.method).toBe('heart rate reserve (Karvonen)')
  })

  test('the top of the last zone is the maximum itself', () => {
    const result = heartRateZones({ observedMax: observed, restingHeartRate: 59 })
    expect(result.zones.at(-1)!.to).toBe(187)
  })

  test('falls back to the age formula when too few workouts measured one', () => {
    const result = heartRateZones({ observedMax: { value: 150, workouts: 2 }, restingHeartRate: 59, age: 28 })
    expect(result.source).toBe('estimated')
    expect(result.max).toBe(estimatedMaxFor(28))
    expect(result.note).toContain('±10')
  })

  test('without a resting pulse the zones are plain percentages of maximum', () => {
    const result = heartRateZones({ observedMax: observed })
    expect(result.method).toBe('percent of maximum')
    expect(result.zones[1]!.from).toBe(112)
  })

  test('with neither a measurement nor an age it says so instead of guessing', () => {
    const result = heartRateZones({})
    expect(result.max).toBeNull()
    expect(result.zones).toEqual([])
  })

  test('the age formula is Tanaka, not 220 minus age', () => {
    expect(estimatedMaxFor(28)).toBe(188)
    expect(estimatedMaxFor(50)).toBe(173)
  })
})
