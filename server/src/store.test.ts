import { describe, expect, test } from 'bun:test'
import { dailyDocs, hourlyDocs } from './store'

// These documents are written with `{ merge: true }`. Firestore merges a nested map leaf by
// leaf, but an empty map has no leaves and is written as a value, replacing what is stored —
// which is how a sync carrying only activity rings erased four days of statistics.
describe('daily documents', () => {
  const ring = { date: '2026-10-25', activeEnergyKcal: 742, activeEnergyGoalKcal: 320 }

  test('rings alone carry no metrics field', () => {
    const doc = dailyDocs([], [ring]).get('2026-10-25')!
    expect(doc.activity).toBeDefined()
    expect('metrics' in doc).toBe(false)
  })

  test('statistics still land under their type', () => {
    const doc = dailyDocs([{ date: '2026-10-25', type: 'restingHeartRate', unit: 'count/min', avg: 61 } as never], [ring]).get('2026-10-25')!
    expect(doc.metrics.restingHeartRate.avg).toBe(61)
    expect(doc.activity.activeEnergyKcal).toBe(742)
  })

  test('a day with statistics and no rings keeps its metrics', () => {
    const doc = dailyDocs([{ date: '2026-10-24', type: 'stepCount', unit: 'count', sum: 9000 } as never], []).get('2026-10-24')!
    expect(doc.metrics.stepCount.sum).toBe(9000)
    expect(doc.activity).toBeUndefined()
  })
})

describe('hourly documents', () => {
  test('hours are kept per metric', () => {
    const doc = hourlyDocs([
      { date: '2026-10-25', hour: 6, type: 'heartRate', unit: 'count/min', avg: 143 } as never,
      { date: '2026-10-25', hour: 7, type: 'heartRate', unit: 'count/min', avg: 159 } as never,
    ]).get('2026-10-25')!
    expect(Object.keys(doc.metrics.heartRate)).toEqual(['6', '7'])
  })

  test('nothing to write produces no document', () => {
    expect(hourlyDocs([]).size).toBe(0)
  })
})
