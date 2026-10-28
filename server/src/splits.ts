// Per-kilometre splits for a workout.
//
// The coaching question after a run is almost always "did the second half slow down, or did the
// heat just push the pulse up" — and that needs splits, not an average. Apple records distance
// as a stream of increments, so the cumulative total is rebuilt here and read at each kilometre
// boundary. Pace between boundaries is interpolated, since a sample almost never lands exactly
// on one.

export interface DistanceSample {
  /** ISO timestamp the increment covers up to. */
  at: string
  /** Metres covered since the previous sample. */
  metres: number
}

export interface HeartRateSample {
  at: string
  value: number
}

export interface Split {
  /** 1 for the first kilometre, and so on. The last one is usually partial. */
  km: number
  /** Metres in this split: 1000 except for the last. */
  metres: number
  seconds: number
  /** Seconds per kilometre, so "5:30" is 330. */
  pace: number
  /** Mean heart rate over the split, when there are readings inside it. */
  heartRate?: number
}

const EPSILON = 0.001

/**
 * Splits from raw distance increments. Samples may arrive in any order and may overlap the
 * recovery tail; only the ones inside the workout window should be passed in.
 */
export function splitsFromDistance(samples: DistanceSample[], heartRate: HeartRateSample[] = [], metresPerSplit = 1000): Split[] {
  const points = samples
    .map((s) => ({ at: new Date(s.at).getTime(), metres: s.metres }))
    .filter((s) => Number.isFinite(s.at) && Number.isFinite(s.metres) && s.metres >= 0)
    .sort((a, b) => a.at - b.at)
  if (points.length < 2) return []

  const beats = heartRate
    .map((s) => ({ at: new Date(s.at).getTime(), value: s.value }))
    .filter((s) => Number.isFinite(s.at) && Number.isFinite(s.value))
    .sort((a, b) => a.at - b.at)

  const splits: Split[] = []
  let cumulative = 0
  let splitStartAt = points[0]!.at
  let splitStartMetres = 0
  let previousAt = points[0]!.at

  for (const point of points) {
    const before = cumulative
    cumulative += point.metres

    // One sample can cross several boundaries if the watch batched it.
    while (cumulative + EPSILON >= splitStartMetres + metresPerSplit) {
      const target = splitStartMetres + metresPerSplit
      const covered = cumulative - before
      // Where in this sample's span the boundary falls.
      const fraction = covered > 0 ? (target - before) / covered : 1
      const crossedAt = previousAt + (point.at - previousAt) * fraction
      const seconds = (crossedAt - splitStartAt) / 1000
      splits.push(describe(splits.length + 1, metresPerSplit, seconds, splitStartAt, crossedAt, beats))
      splitStartAt = crossedAt
      splitStartMetres = target
    }

    previousAt = point.at
  }

  // Whatever is left over after the last whole kilometre.
  const remainder = cumulative - splitStartMetres
  if (remainder > 1) {
    const seconds = (previousAt - splitStartAt) / 1000
    splits.push(describe(splits.length + 1, Math.round(remainder), seconds, splitStartAt, previousAt, beats))
  }
  return splits
}

function describe(km: number, metres: number, seconds: number, from: number, to: number, beats: { at: number; value: number }[]): Split {
  const inside = beats.filter((b) => b.at >= from && b.at <= to)
  const split: Split = {
    km,
    metres,
    seconds: Math.round(seconds),
    pace: metres > 0 ? Math.round((seconds / metres) * 1000) : 0,
  }
  if (inside.length) split.heartRate = Math.round(inside.reduce((sum, b) => sum + b.value, 0) / inside.length)
  return split
}

/** "5:30" from 330 seconds, which is how a runner reads a pace. */
export function paceLabel(secondsPerKm: number) {
  const minutes = Math.floor(secondsPerKm / 60)
  return `${minutes}:${String(Math.round(secondsPerKm - minutes * 60)).padStart(2, '0')}`
}
