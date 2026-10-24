import { describe, expect, test } from 'bun:test'
import { bandFor, computeReadiness } from './readiness'

// The numbers in these tests are the user's real values on 24 Oct 2026, so a change in the
// formula shows up as a change in a score someone has actually seen.
const realDay = {
  hrv: { latest: 50.883, baseline: 62.495 },
  restingHeartRate: { latest: 67, baseline: 59.965 },
  sleepMinutes: 394,
  load: { acute: 58, chronic: 30.066 },
}

describe('bands', () => {
  test('boundaries land where the table says', () => {
    expect(bandFor(0).key).toBe('recover')
    expect(bandFor(34).key).toBe('recover')
    expect(bandFor(35).key).toBe('caution')
    expect(bandFor(54).key).toBe('caution')
    expect(bandFor(55).key).toBe('ready')
    expect(bandFor(79).key).toBe('ready')
    expect(bandFor(80).key).toBe('primed')
    expect(bandFor(100).key).toBe('primed')
  })
})

describe('scoring', () => {
  test('a hard day with suppressed HRV scores in the caution band', () => {
    const result = computeReadiness(realDay)
    expect(result.score).toBeGreaterThan(30)
    expect(result.score).toBeLessThan(55)
    expect(result.band).toBe('caution')
    expect(result.advice).toBe('วันนี้เหมาะกับซ้อมเบาหรือพัก')
  })

  test('a rested day with everything at baseline scores high', () => {
    const result = computeReadiness({
      hrv: { latest: 70, baseline: 62 },
      restingHeartRate: { latest: 57, baseline: 60 },
      sleepMinutes: 480,
      load: { acute: 30, chronic: 30 },
    })
    expect(result.score).toBeGreaterThanOrEqual(80)
    expect(result.band).toBe('primed')
    expect(result.headline).toContain('ทุกค่าอยู่ในช่วงปกติ')
  })

  test('is deterministic', () => {
    expect(computeReadiness(realDay)).toEqual(computeReadiness(realDay))
  })

  test('scores stay inside 0-100 however extreme the inputs', () => {
    const awful = computeReadiness({
      hrv: { latest: 1, baseline: 100 },
      restingHeartRate: { latest: 120, baseline: 50 },
      sleepMinutes: 0,
      load: { acute: 600, chronic: 10 },
    })
    expect(awful.score).toBe(0)
    const impossible = computeReadiness({
      hrv: { latest: 500, baseline: 50 },
      restingHeartRate: { latest: 30, baseline: 60 },
      sleepMinutes: 900,
      load: { acute: 30, chronic: 30 },
    })
    expect(impossible.score).toBe(100)
  })
})

describe('factor direction', () => {
  test('a small HRV dip is watched, a large one is bad', () => {
    // −4.8% still counts as normal variation; −10% is the first notch.
    const normal = computeReadiness({ ...realDay, hrv: { latest: 59, baseline: 62 } })
    expect(normal.factors.find((f) => f.key === 'hrv')?.direction).toBe('good')
    const mild = computeReadiness({ ...realDay, hrv: { latest: 56, baseline: 62 } })
    expect(mild.factors.find((f) => f.key === 'hrv')?.direction).toBe('watch')
    const severe = computeReadiness({ ...realDay, hrv: { latest: 40, baseline: 62 } })
    expect(severe.factors.find((f) => f.key === 'hrv')?.direction).toBe('bad')
  })

  test('load within the sweet spot is not penalised', () => {
    const steady = computeReadiness({ ...realDay, load: { acute: 33, chronic: 30 } })
    expect(steady.factors.find((f) => f.key === 'load')?.score).toBe(100)
  })

  test('detraining costs less than a spike', () => {
    const quiet = computeReadiness({ ...realDay, load: { acute: 5, chronic: 30 } })
    const spike = computeReadiness({ ...realDay, load: { acute: 90, chronic: 30 } })
    const quietScore = quiet.factors.find((f) => f.key === 'load')!.score
    const spikeScore = spike.factors.find((f) => f.key === 'load')!.score
    expect(quietScore).toBeGreaterThan(spikeScore)
  })
})

describe('partial data', () => {
  test('missing factors are named and the rest still score', () => {
    const result = computeReadiness({ hrv: realDay.hrv, sleepMinutes: 420 })
    expect(result.score).not.toBeNull()
    expect(result.missing).toEqual(['restingHeartRate', 'load'])
    expect(result.weightsUsed).toBe(0.6)
  })

  test('weights are renormalised, not just dropped', () => {
    // Sleep alone at 100 and HRV alone at 50 must average by their relative weights, not fall
    // towards zero because half the weight is absent.
    const result = computeReadiness({ hrv: { latest: 62, baseline: 62 }, sleepMinutes: 480 })
    expect(result.score).toBe(75)
  })

  test('one factor is not enough', () => {
    const result = computeReadiness({ sleepMinutes: 480 })
    expect(result.score).toBeNull()
    expect(result.missing).toHaveLength(3)
  })

  test('nothing at all is handled', () => {
    expect(computeReadiness({}).score).toBeNull()
  })

  test('a zero baseline does not divide by zero', () => {
    const result = computeReadiness({ hrv: { latest: 50, baseline: 0 }, sleepMinutes: 480, restingHeartRate: { latest: 60, baseline: 60 } })
    expect(result.missing).toContain('hrv')
    expect(Number.isFinite(result.score!)).toBe(true)
  })
})

describe('wording', () => {
  test('names the two worst factors, worst first', () => {
    const result = computeReadiness(realDay)
    expect(result.headline).toContain('ชีพจรพักสูงขึ้น')
    expect(result.headline).toContain('HRV ต่ำกว่าค่าฐาน')
    expect(result.headline!.indexOf('ชีพจรพัก')).toBeLessThan(result.headline!.indexOf('HRV'))
  })

  test('always ends with the advice for the band', () => {
    const result = computeReadiness(realDay)
    expect(result.headline!.endsWith(result.advice!)).toBe(true)
  })
})
