import { describe, expect, test } from 'bun:test'
import { catalog } from './catalog'
import { aggregateWindow, defaults, groupOf, sampleWindow, settingsFrom, usesRawWindow, validate } from './retention'

const DAY = 86_400_000
const YEAR = 365.25 * DAY

describe('which group a metric belongs to', () => {
  test('raw high-frequency signals', () => {
    expect(groupOf('heartRate')).toBe('raw')
    expect(groupOf('runningSpeed')).toBe('raw')
  })

  test('recovery signals', () => {
    expect(groupOf('sleepAnalysis')).toBe('recovery')
    expect(groupOf('heartRateVariabilitySDNN')).toBe('recovery')
  })

  test('body measurements', () => {
    expect(groupOf('bodyMass')).toBe('body')
    expect(groupOf('vo2Max')).toBe('body')
  })

  test('and everything else trains', () => {
    expect(groupOf('stepCount')).toBe('training')
    expect(groupOf('somethingAddedLater')).toBe('training')
  })

  test('every metric in the catalog has one', () => {
    const all = [...catalog.quantities, ...catalog.categories]
    expect(all.every((m) => m.group)).toBe(true)
  })
})

describe('which window a sample follows', () => {
  const settings = defaults

  test('raw heart rate ages out on the short window', () => {
    expect(sampleWindow('heartRate', false, settings)).toBe(7 * DAY)
  })

  test('unless it was recorded during a workout', () => {
    // The heart rate inside a run is the run: losing it would take the splits with it.
    expect(sampleWindow('heartRate', true, settings)).toBe(5 * YEAR)
  })

  test('a night of sleep follows the recovery window', () => {
    expect(sampleWindow('sleepAnalysis', false, settings)).toBe(5 * YEAR)
  })

  test('a weigh-in follows the body window', () => {
    expect(sampleWindow('bodyMass', false, settings)).toBe(10 * YEAR)
  })

  test('residue from a metric that is now aggregate-only ages out quickly', () => {
    expect(usesRawWindow('stepCount')).toBe(true)
    expect(sampleWindow('stepCount', false, settings)).toBe(7 * DAY)
  })

  test('aggregates and workouts follow training', () => {
    expect(aggregateWindow(settings)).toBe(5 * YEAR)
  })
})

describe('reading stored settings', () => {
  test('a profile with nothing saved gets the defaults', () => {
    expect(settingsFrom(undefined)).toEqual(defaults)
  })

  test('a saved choice is kept', () => {
    expect(settingsFrom({ raw: 30, body: 2 }).raw).toBe(30)
    expect(settingsFrom({ raw: 30, body: 2 }).body).toBe(2)
  })

  test('a value no longer on offer falls back rather than sticking', () => {
    expect(settingsFrom({ raw: 3 }).raw).toBe(defaults.raw)
  })

  test('an older profile carries its single choice into every yearly group', () => {
    const migrated = settingsFrom(undefined, 2)
    expect(migrated.recovery).toBe(2)
    expect(migrated.body).toBe(2)
    expect(migrated.training).toBe(2)
    // Raw was never measured in years, so it takes its own default.
    expect(migrated.raw).toBe(defaults.raw)
  })
})

describe('validating a change', () => {
  test('accepts a window the group offers', () => {
    expect(validate({ raw: 14 })).toEqual({ raw: 14 })
  })

  test('refuses one it does not', () => {
    expect(() => validate({ raw: 365 })).toThrow()
    expect(() => validate({ recovery: 3 })).toThrow()
  })

  test('ignores keys that are not groups', () => {
    expect(validate({ nonsense: 5 })).toEqual({})
  })
})
