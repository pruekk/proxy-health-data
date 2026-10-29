import { describe, expect, test } from 'bun:test'
import { PlanRejected, outcomeFor, validateDay, wentHarder, type PlanDay } from './plans'

const TODAY = '2026-10-29'
const day = (over: Record<string, unknown> = {}) => ({ date: '2026-10-30', type: 'easy', ...over })

describe('writing a plan', () => {
  test('a future day is accepted and cleaned up', () => {
    const result = validateDay(day({ totalMinutes: 65, note: 'เบาจริง ๆ' }), TODAY, false)
    expect(result.date).toBe('2026-10-30')
    expect(result.type).toBe('easy')
    expect(result.totalMinutes).toBe(65)
  })

  test('the past cannot be rewritten', () => {
    expect(() => validateDay(day({ date: '2026-10-28' }), TODAY, false)).toThrow(PlanRejected)
  })

  test('today is open until something has been recorded', () => {
    expect(validateDay(day({ date: TODAY }), TODAY, false).date).toBe(TODAY)
    expect(() => validateDay(day({ date: TODAY }), TODAY, true)).toThrow(/ออกกำลังกายไปแล้ว/)
  })

  test('refuses a type it does not know, and says which it takes', () => {
    expect(() => validateDay(day({ type: 'sprints' }), TODAY, false)).toThrow(/threshold/)
  })

  test('refuses to plan further out than the horizon', () => {
    expect(() => validateDay(day({ date: '2027-06-01' }), TODAY, false)).toThrow(/ล่วงหน้า/)
  })

  test('a pace range given backwards is put the right way round', () => {
    const result = validateDay(
      day({ steps: [{ phase: 'main', paceSecPerKm: [475, 434] }] }),
      TODAY,
      false,
    )
    expect(result.steps![0]!.paceSecPerKm).toEqual([434, 475])
  })

  test('refuses a phase that is not part of a session', () => {
    expect(() => validateDay(day({ steps: [{ phase: 'lunch' }] }), TODAY, false)).toThrow(/phase/)
  })
})

describe('what became of a day', () => {
  const ran = [{ activityTypeName: 'running' }]
  const climbed = [{ activityTypeName: 'climbing' }]

  test('a future day with a plan is simply planned', () => {
    expect(outcomeFor({ date: '2026-11-02', today: TODAY, plan: { type: 'easy' }, actuals: [] }).outcome).toBe('planned')
  })

  test('a run where a run was planned is done', () => {
    expect(outcomeFor({ date: '2026-10-28', today: TODAY, plan: { type: 'interval' }, actuals: ran }).outcome).toBe('done')
  })

  test('climbing where a run was planned is a different session, not a failure', () => {
    expect(outcomeFor({ date: '2026-10-28', today: TODAY, plan: { type: 'easy' }, actuals: climbed }).outcome).toBe('different')
  })

  test('a planned session with nothing recorded is missed', () => {
    expect(outcomeFor({ date: '2026-10-28', today: TODAY, plan: { type: 'easy' }, actuals: [] }).outcome).toBe('missed')
  })

  test('but today is still open, so it is not missed yet', () => {
    expect(outcomeFor({ date: TODAY, today: TODAY, plan: { type: 'easy' }, actuals: [] }).outcome).toBe('planned')
  })

  test('a rest day taken is rest; a rest day run is different', () => {
    expect(outcomeFor({ date: '2026-10-28', today: TODAY, plan: { type: 'rest' }, actuals: [] }).outcome).toBe('rest')
    expect(outcomeFor({ date: '2026-10-28', today: TODAY, plan: { type: 'rest' }, actuals: ran }).outcome).toBe('different')
  })

  test('a session nobody planned is still recorded', () => {
    expect(outcomeFor({ date: '2026-10-28', today: TODAY, actuals: ran }).outcome).toBe('unplanned')
  })

  test('an empty day with no plan is nothing at all', () => {
    expect(outcomeFor({ date: '2026-10-28', today: TODAY, actuals: [] }).outcome).toBe('none')
  })
})

describe('whether it went harder than written', () => {
  const plan: PlanDay = {
    date: '2026-10-24',
    type: 'interval',
    steps: [{ phase: 'main', paceSecPerKm: [425, 435], zone: 4 }],
  }

  test('faster than the quick end of the range counts', () => {
    // Written for 7:05–7:15, run at 5:46.
    expect(wentHarder(plan, [{ paceSecPerKm: 346 }])).toBe(true)
  })

  test('inside the range does not', () => {
    expect(wentHarder(plan, [{ paceSecPerKm: 430 }])).toBe(false)
  })

  test('a pulse above the zone it was written for counts', () => {
    expect(wentHarder(plan, [{ avgHeartRate: 171 }], 163)).toBe(true)
  })

  test('nothing to compare against is not an accusation', () => {
    expect(wentHarder(undefined, [{ paceSecPerKm: 300 }])).toBe(false)
    expect(wentHarder(plan, [])).toBe(false)
  })
})
