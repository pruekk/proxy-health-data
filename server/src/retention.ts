// Retention, decided per group rather than per user.
//
// A day of raw heart rate is hundreds of documents that the hourly buckets already summarise; a
// weigh-in is one document a month that only means something as a multi-year line. One window
// for both forces a choice between losing the line and paying for the noise.
//
// Nothing is kept forever: this service is a copy, Apple Health holds the original, and a full
// re-sync brings back whatever Health still has.

import { catalog, type GroupId } from './catalog'

export type RetentionSettings = Record<GroupId, number>

const groups = catalog.retentionGroups
const byId = new Map(groups.map((g) => [g.id, g]))

/** The group a metric's own samples belong to. */
const metricGroups = new Map<string, GroupId>(
  [...catalog.quantities, ...catalog.categories].map((m) => [m.key, (m.group ?? 'training') as GroupId]),
)

/**
 * Metrics whose raw samples follow the raw window even though the metric itself belongs
 * elsewhere: the cumulative ones are no longer uploaded raw at all, so anything still stored is
 * residue that should age out on the short window rather than linger for years.
 */
const aggregateOnly = new Set(catalog.quantities.filter((q) => q.raw === false).map((q) => q.key))

export const defaults: RetentionSettings = Object.fromEntries(
  groups.map((g) => [g.id, g.default]),
) as RetentionSettings

export function groupOf(type: string): GroupId {
  return metricGroups.get(type) ?? 'training'
}

/** Whether a metric's raw samples are governed by the raw window. */
export function usesRawWindow(type: string) {
  return groupOf(type) === 'raw' || aggregateOnly.has(type)
}

const DAY_MS = 86_400_000
const YEAR_MS = 365.25 * DAY_MS

/** How long a group keeps things, in milliseconds. */
export function windowFor(group: GroupId, settings: RetentionSettings) {
  const meta = byId.get(group)
  const value = settings[group] ?? defaults[group]
  return meta?.unit === 'days' ? value * DAY_MS : value * YEAR_MS
}

/**
 * When a sample expires. Samples recorded during a workout follow the training group however
 * high-frequency they are — the heart rate inside a run is the run, and losing it after a week
 * would take the splits and the drift with it.
 */
export function sampleWindow(type: string, inWorkout: boolean, settings: RetentionSettings) {
  if (inWorkout) return windowFor('training', settings)
  return windowFor(usesRawWindow(type) ? 'raw' : groupOf(type), settings)
}

/** Aggregates and workouts all belong to the training group. */
export const aggregateWindow = (settings: RetentionSettings) => windowFor('training', settings)

/**
 * Settings as stored, filled in from the defaults. Older profiles carry a single
 * `retentionYears`, which becomes the window for every group measured in years.
 */
export function settingsFrom(stored: unknown, legacyYears?: number): RetentionSettings {
  const saved = (stored ?? {}) as Partial<Record<GroupId, unknown>>
  return Object.fromEntries(
    groups.map((g) => {
      const value = saved[g.id]
      if (typeof value === 'number' && g.options.includes(value)) return [g.id, value]
      if (g.unit === 'years' && typeof legacyYears === 'number' && legacyYears > 0) {
        // Keep the user's old choice where it is still on offer, rather than silently widening.
        return [g.id, g.options.includes(legacyYears) ? legacyYears : g.default]
      }
      return [g.id, g.default]
    }),
  ) as RetentionSettings
}

/** Rejects anything not on the group's own list of windows. */
export function validate(input: Record<string, unknown>) {
  const out: Partial<RetentionSettings> = {}
  for (const group of groups) {
    const value = input[group.id]
    if (value === undefined) continue
    if (typeof value !== 'number' || !group.options.includes(value)) {
      throw new Error(`${group.id} ต้องเป็นหนึ่งใน ${group.options.join(', ')}`)
    }
    out[group.id] = value
  }
  return out
}

/** The scopes `applyRetention` walks, in the order the UI reports progress for. */
export const retentionScopes = [
  ...[...metricGroups.keys()].sort(),
  'daily',
  'hourly',
  'workouts',
]
