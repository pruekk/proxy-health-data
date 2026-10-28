import { describe, expect, test } from 'bun:test'
import { estimatedMaxFor, heartRateZones } from './zones'

/** A real set: a smooth top end with no single reading standing apart from the rest. */
const observed = [
  { value: 187, at: '2026-10-21' },
  { value: 185, at: '2026-09-04' },
  { value: 184, at: '2026-10-07' },
  { value: 182, at: '2026-09-22' },
  { value: 181, at: '2026-03-28' },
]

describe('heart-rate zones', () => {
  test('prefers the heart rate actually recorded', () => {
    const result = heartRateZones({ observed, restingHeartRate: 59, age: 28 })
    expect(result.max).toBe(187)
    expect(result.source).toBe('measured')
    expect(result.measuredAt).toBe('2026-10-21')
  })

  test('zones span resting to maximum, not zero to maximum', () => {
    const result = heartRateZones({ observed, restingHeartRate: 59, age: 28 })
    // Reserve is 128; zone 2 runs from 60% to 70% of it, above resting.
    expect(result.zones[1]!.from).toBe(136)
    expect(result.zones[1]!.to).toBe(149)
    expect(result.method).toBe('heart rate reserve (Karvonen)')
  })

  test('the top of the last zone is the maximum itself', () => {
    const result = heartRateZones({ observed, restingHeartRate: 59 })
    expect(result.zones.at(-1)!.to).toBe(187)
  })

  test('falls back to the age formula when too few workouts measured one', () => {
    const result = heartRateZones({ observed: [{ value: 150 }, { value: 148 }], restingHeartRate: 59, age: 28 })
    expect(result.source).toBe('estimated')
    expect(result.max).toBe(estimatedMaxFor(28))
    expect(result.note).toContain('±10')
  })

  test('without a resting pulse the zones are plain percentages of maximum', () => {
    const result = heartRateZones({ observed })
    expect(result.method).toBe('percent of maximum')
    expect(result.zones[1]!.from).toBe(112)
  })

  test('with neither a measurement nor an age it says so instead of guessing', () => {
    const result = heartRateZones({})
    expect(result.max).toBeNull()
    expect(result.zones).toEqual([])
  })

  test('a lone spike does not set the zones', () => {
    // A wrist sensor locking onto cadence reports a rate that was never reached.
    const result = heartRateZones({ observed: [{ value: 214, at: '2026-05-02' }, ...observed], restingHeartRate: 59 })
    expect(result.max).toBe(187)
    expect(result.measuredAt).toBe('2026-10-21')
  })

  test('but a peak the next reading stands near is kept', () => {
    const result = heartRateZones({ observed: [{ value: 189, at: '2026-04-11' }, ...observed], restingHeartRate: 59 })
    expect(result.max).toBe(189)
  })

  test('the age formula is Tanaka, not 220 minus age', () => {
    expect(estimatedMaxFor(28)).toBe(188)
    expect(estimatedMaxFor(50)).toBe(173)
  })
})
