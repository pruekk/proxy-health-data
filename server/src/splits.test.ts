import { describe, expect, test } from 'bun:test'
import { paceLabel, splitsFromDistance, type DistanceSample } from './splits'

/** A run at a steady pace: one sample every ten seconds covering `metresPer10s`. */
const steady = (count: number, metresPer10s: number, startMs = 0): DistanceSample[] =>
  Array.from({ length: count }, (_, i) => ({
    at: new Date(startMs + (i + 1) * 10_000).toISOString(),
    metres: metresPer10s,
  }))

describe('splits from distance increments', () => {
  test('a steady two kilometres splits into two even kilometres', () => {
    // 50 m per 10 s is 5 m/s, so a kilometre takes 200 s — 3:20/km.
    const splits = splitsFromDistance([{ at: new Date(0).toISOString(), metres: 0 }, ...steady(40, 50)])
    expect(splits.length).toBe(2)
    expect(splits[0]!.pace).toBe(200)
    expect(splits[1]!.pace).toBe(200)
    expect(splits[0]!.seconds).toBe(200)
  })

  test('a slower second kilometre shows up as a slower split', () => {
    const first = steady(20, 50) // 1 km in 200 s
    const second = Array.from({ length: 25 }, (_, i) => ({
      at: new Date(200_000 + (i + 1) * 10_000).toISOString(),
      metres: 40, // 1 km in 250 s
    }))
    const splits = splitsFromDistance([{ at: new Date(0).toISOString(), metres: 0 }, ...first, ...second])
    expect(splits[0]!.pace).toBe(200)
    expect(splits[1]!.pace).toBe(250)
  })

  test('the last partial kilometre is reported as its own split', () => {
    const splits = splitsFromDistance([{ at: new Date(0).toISOString(), metres: 0 }, ...steady(30, 50)])
    expect(splits.length).toBe(2)
    expect(splits[1]!.metres).toBe(500)
    expect(splits[1]!.km).toBe(2)
  })

  test('a boundary inside one sample is interpolated rather than rounded to the sample', () => {
    // 300 m every 60 s: the first kilometre ends part-way through the fourth sample.
    const samples = Array.from({ length: 4 }, (_, i) => ({
      at: new Date((i + 1) * 60_000).toISOString(),
      metres: 300,
    }))
    const splits = splitsFromDistance([{ at: new Date(0).toISOString(), metres: 0 }, ...samples])
    // 1000 m at 5 m/s is exactly 200 s.
    expect(splits[0]!.seconds).toBe(200)
  })

  test('one batched sample crossing several kilometres still produces one split each', () => {
    const splits = splitsFromDistance([
      { at: new Date(0).toISOString(), metres: 0 },
      { at: new Date(900_000).toISOString(), metres: 3000 },
    ])
    expect(splits.map((s) => s.km)).toEqual([1, 2, 3])
    expect(splits.every((s) => s.pace === 300)).toBe(true)
  })

  test('heart rate is averaged within each split', () => {
    const splits = splitsFromDistance(
      [{ at: new Date(0).toISOString(), metres: 0 }, ...steady(40, 50)],
      [
        { at: new Date(100_000).toISOString(), value: 140 },
        { at: new Date(150_000).toISOString(), value: 150 },
        { at: new Date(300_000).toISOString(), value: 170 },
      ],
    )
    expect(splits[0]!.heartRate).toBe(145)
    expect(splits[1]!.heartRate).toBe(170)
  })

  test('samples out of order are sorted rather than trusted', () => {
    const ordered = [{ at: new Date(0).toISOString(), metres: 0 }, ...steady(20, 50)]
    const shuffled = [...ordered].reverse()
    expect(splitsFromDistance(shuffled)).toEqual(splitsFromDistance(ordered))
  })

  test('too little data produces nothing rather than a wrong number', () => {
    expect(splitsFromDistance([])).toEqual([])
    expect(splitsFromDistance([{ at: new Date(0).toISOString(), metres: 500 }])).toEqual([])
  })

  test('a walk that never reaches a kilometre is one partial split', () => {
    const splits = splitsFromDistance([{ at: new Date(0).toISOString(), metres: 0 }, ...steady(10, 30)])
    expect(splits.length).toBe(1)
    expect(splits[0]!.metres).toBe(300)
  })
})

describe('pace labels', () => {
  test('reads the way a runner says it', () => {
    expect(paceLabel(300)).toBe('5:00')
    expect(paceLabel(335)).toBe('5:35')
    expect(paceLabel(605)).toBe('10:05')
  })
})
