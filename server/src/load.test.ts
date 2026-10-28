import { describe, expect, test } from 'bun:test'
import { daysBetween, loadWindows, shiftDate } from './load'

/** `days` worth of dates ending on `to`, each holding `minutes`. */
const steady = (to: string, days: number, minutes: number) =>
  new Map(Array.from({ length: days }, (_, i) => [shiftDate(to, -i), minutes]))

describe('training load windows', () => {
  test('a steady history gives a ratio of one', () => {
    const result = loadWindows(steady('2026-10-28', 120, 30), '2026-10-28')!
    // Windows end yesterday, so today being empty or half-done changes nothing.
    expect(result.acute).toBe(30)
    expect(result.chronic).toBe(30)
  })

  test('a day with nothing recorded counts as zero, not as missing', () => {
    // Four sessions of 70 minutes in the last week, nothing on the other three days.
    const byDate = new Map([
      ['2026-10-27', 70],
      ['2026-10-25', 70],
      ['2026-10-23', 70],
      ['2026-10-21', 70],
    ])
    const result = loadWindows(byDate, '2026-10-28')!
    // 280 minutes over seven days, not 70 over four.
    expect(result.acute).toBe(40)
  })

  test('the chronic window grows with the history behind it', () => {
    // Forty days of records, of which thirty-nine are complete days behind today.
    expect(loadWindows(steady('2026-10-28', 40, 30), '2026-10-28')!.chronicDays).toBe(39)
    expect(loadWindows(steady('2026-10-28', 200, 30), '2026-10-28')!.chronicDays).toBe(90)
  })

  test('and never shrinks below four weeks', () => {
    const result = loadWindows(steady('2026-10-28', 10, 30), '2026-10-28')!
    expect(result.chronicDays).toBe(28)
    expect(result.historyDays).toBe(9)
  })

  test('today is left out, since the morning score is about days already lived', () => {
    const byDate = steady('2026-10-28', 90, 30)
    byDate.set('2026-10-28', 0)
    expect(loadWindows(byDate, '2026-10-28')!.acute).toBe(30)
  })

  test('a heavy week against a quiet history reads as a spike', () => {
    const byDate = steady('2026-10-28', 90, 20)
    for (let i = 1; i <= 7; i += 1) byDate.set(shiftDate('2026-10-28', -i), 60)
    const result = loadWindows(byDate, '2026-10-28')!
    expect(result.acute).toBe(60)
    expect(Number((result.acute / result.chronic).toFixed(2))).toBeGreaterThan(2)
  })

  test('no history at all produces nothing rather than a divide by zero', () => {
    expect(loadWindows(new Map(), '2026-10-28')).toBeUndefined()
    expect(loadWindows(new Map([['2026-10-28', 0]]), '2026-10-28')).toBeUndefined()
  })

  test('dates shift and subtract across month ends', () => {
    expect(shiftDate('2026-11-01', -1)).toBe('2026-10-31')
    expect(daysBetween('2026-10-28', '2026-11-04')).toBe(7)
  })
})
