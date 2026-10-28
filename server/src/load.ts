// Training load as an acute-to-chronic workload ratio.
//
// Two things make this easy to get wrong, and both were wrong here. A day with no exercise
// recorded is a day of no exercise, not a day to leave out of the average — dropping it compares
// a per-calendar-day acute figure against a per-active-day chronic one, and the ratio that comes
// out is neither. And the chronic window cannot be longer than the history behind it: four weeks
// into running there is no ninety-day normal, so comparing against one makes every week a spike.

import { catalog } from './catalog'

const config = catalog.load

export interface LoadWindows {
  acute: number
  chronic: number
  acuteDays: number
  chronicDays: number
  /** Days of history the chronic window had to work with. */
  historyDays: number
}

/**
 * Windows end on the last complete day rather than today: readiness is worked out in the
 * morning, when today has barely happened, and counting it as a day of almost no exercise
 * drags the recent average down by a seventh for no reason.
 *
 * @param byDate minutes per local date, missing dates treated as zero
 * @param today  the local date now — the windows end on the day before it
 */
export function loadWindows(byDate: Map<string, number>, today: string): LoadWindows | undefined {
  const dates = [...byDate.keys()].sort()
  if (!dates.length) return undefined

  const lastComplete = shiftDate(today, -1)
  const historyDays = daysBetween(dates[0]!, lastComplete) + 1
  if (historyDays < 1) return undefined
  const chronicDays = Math.min(Math.max(historyDays, config.minChronicDays), config.maxChronicDays)
  const acuteDays = config.acuteDays

  const mean = (days: number) => {
    let total = 0
    for (let back = 0; back < days; back += 1) total += byDate.get(shiftDate(lastComplete, -back)) ?? 0
    return total / days
  }

  const chronic = mean(chronicDays)
  if (chronic <= 0) return undefined
  return { acute: mean(acuteDays), chronic, acuteDays, chronicDays, historyDays }
}

const DAY_MS = 86_400_000

export function shiftDate(date: string, days: number) {
  return new Date(new Date(`${date}T00:00:00Z`).getTime() + days * DAY_MS).toISOString().slice(0, 10)
}

export function daysBetween(from: string, to: string) {
  return Math.round((new Date(`${to}T00:00:00Z`).getTime() - new Date(`${from}T00:00:00Z`).getTime()) / DAY_MS)
}
