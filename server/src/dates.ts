import { BadRequest, type Range } from './store'

const DAY_MS = 86_400_000

function parse(value: string, name: string): Date {
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) throw new BadRequest(`invalid ${name}: ${value}`)
  return date
}

// `from`/`to` accept ISO dates or datetimes. A bare `to` date (YYYY-MM-DD) includes that whole day.
export function parseRange(from: string | undefined, to: string | undefined, defaultDays: number): Range {
  const end = to ? parse(to, 'to') : new Date()
  if (to && /^\d{4}-\d{2}-\d{2}$/.test(to)) end.setTime(end.getTime() + DAY_MS)
  const start = from ? parse(from, 'from') : new Date(end.getTime() - defaultDays * DAY_MS)
  if (start >= end) throw new BadRequest('`from` must be before `to`')
  return { from: start, to: end }
}

export function localDateKey(date: Date, timeZone: string): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' }).format(date)
}

// Daily docs are keyed by the phone's local date, so default ranges are computed in the user's time zone.
export function parseDateKeys(from: string | undefined, to: string | undefined, defaultDays: number, timeZone: string) {
  const key = /^\d{4}-\d{2}-\d{2}$/
  for (const [name, value] of [['from', from], ['to', to]] as const) {
    if (value && !key.test(value)) throw new BadRequest(`${name} must be YYYY-MM-DD`)
  }
  const toKey = to ?? localDateKey(new Date(), timeZone)
  const fromKey = from ?? localDateKey(new Date(Date.parse(toKey) - (defaultDays - 1) * DAY_MS), 'UTC')
  if (fromKey > toKey) throw new BadRequest('`from` must not be after `to`')
  return { from: fromKey, to: toKey }
}
