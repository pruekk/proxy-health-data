// Training readiness: one number for "should I train hard today?", computed from the user's own
// 90-day baselines rather than population norms. Deterministic — the same inputs always produce
// the same score and the same wording — so the app and the MCP tools never disagree.
//
// There is no standard for this. Whoop, Garmin and Oura each use their own undisclosed formula,
// so the weights below are a choice, documented here and easy to change.

export interface ReadinessInputs {
  /** Most recent daily average, and the mean over the baseline window. */
  hrv?: { latest: number; baseline: number }
  restingHeartRate?: { latest: number; baseline: number }
  /** Minutes actually asleep last night. */
  sleepMinutes?: number
  /** Exercise minutes: recent average against the long-run average. */
  load?: { acute: number; chronic: number }
  /** Target night's sleep in minutes. */
  sleepTargetMinutes?: number
}

export type FactorKey = 'hrv' | 'restingHeartRate' | 'sleep' | 'load'

export interface Factor {
  key: FactorKey
  score: number
  weight: number
  value: number
  baseline?: number
  /** How far from the baseline, in the unit a reader cares about. */
  deviation?: string
  direction: 'good' | 'watch' | 'bad'
}

const WEIGHTS: Record<FactorKey, number> = {
  hrv: 0.3,
  restingHeartRate: 0.25,
  sleep: 0.3,
  load: 0.15,
}

const SLEEP_TARGET_MINUTES = 480
/** Below two factors the number would be more noise than signal. */
const MINIMUM_FACTORS = 2

const clamp = (value: number) => Math.max(0, Math.min(100, value))
const round = (value: number, places = 1) => Number(value.toFixed(places))

export function computeReadiness(inputs: ReadinessInputs) {
  const factors: Factor[] = []
  const missing: FactorKey[] = []

  // HRV: a drop below your own baseline is the earliest sign of accumulated fatigue.
  // 150 means a 10% drop costs 15 points.
  if (inputs.hrv && inputs.hrv.baseline > 0) {
    const ratio = inputs.hrv.latest / inputs.hrv.baseline
    const percent = (ratio - 1) * 100
    factors.push({
      key: 'hrv',
      score: clamp(50 + (ratio - 1) * 150),
      weight: WEIGHTS.hrv,
      value: round(inputs.hrv.latest),
      baseline: round(inputs.hrv.baseline),
      deviation: `${percent >= 0 ? '+' : '−'}${Math.abs(round(percent, 0))}%`,
      direction: percent >= -5 ? 'good' : percent >= -15 ? 'watch' : 'bad',
    })
  } else {
    missing.push('hrv')
  }

  // Resting heart rate: each beat above baseline costs 5 points.
  if (inputs.restingHeartRate && inputs.restingHeartRate.baseline > 0) {
    const delta = inputs.restingHeartRate.latest - inputs.restingHeartRate.baseline
    factors.push({
      key: 'restingHeartRate',
      score: clamp(50 - delta * 5),
      weight: WEIGHTS.restingHeartRate,
      value: round(inputs.restingHeartRate.latest, 0),
      baseline: round(inputs.restingHeartRate.baseline),
      deviation: `${delta >= 0 ? '+' : '−'}${Math.abs(round(delta, 0))} bpm`,
      direction: delta <= 2 ? 'good' : delta <= 5 ? 'watch' : 'bad',
    })
  } else {
    missing.push('restingHeartRate')
  }

  // Sleep: straight proportion of the target, so eight hours is full marks.
  if (inputs.sleepMinutes !== undefined) {
    const target = inputs.sleepTargetMinutes ?? SLEEP_TARGET_MINUTES
    const ratio = inputs.sleepMinutes / target
    factors.push({
      key: 'sleep',
      score: clamp(ratio * 100),
      weight: WEIGHTS.sleep,
      value: Math.round(inputs.sleepMinutes),
      baseline: target,
      deviation: `${Math.floor(inputs.sleepMinutes / 60)}:${String(Math.round(inputs.sleepMinutes % 60)).padStart(2, '0')}`,
      direction: ratio >= 0.9 ? 'good' : ratio >= 0.75 ? 'watch' : 'bad',
    })
  } else {
    missing.push('sleep')
  }

  // Training load: the acute-to-chronic ratio. Around 0.8-1.3 is the sweet spot; well above it
  // is the classic spike, well below it is detraining and only lightly penalised.
  if (inputs.load && inputs.load.chronic > 0) {
    const ratio = inputs.load.acute / inputs.load.chronic
    const score = ratio > 1.3 ? clamp(100 - (ratio - 1.3) * 100) : ratio < 0.8 ? clamp(70 + ratio * 37.5) : 100
    factors.push({
      key: 'load',
      score,
      weight: WEIGHTS.load,
      value: round(inputs.load.acute, 0),
      baseline: round(inputs.load.chronic, 0),
      deviation: `${round(ratio, 2)}×`,
      direction: ratio <= 1.3 ? 'good' : ratio <= 1.6 ? 'watch' : 'bad',
    })
  } else {
    missing.push('load')
  }

  if (factors.length < MINIMUM_FACTORS) {
    return { score: null, band: null, headline: null, advice: null, factors, missing, weightsUsed: 0 }
  }

  // Weights are renormalised over whatever is present, so a missing factor shifts the balance
  // rather than dragging the score down.
  const weightSum = factors.reduce((sum, f) => sum + f.weight, 0)
  const score = Math.round(factors.reduce((sum, f) => sum + f.score * f.weight, 0) / weightSum)
  const band = bandFor(score)

  return {
    score,
    band: band.key,
    bandLabel: band.label,
    advice: band.advice,
    headline: headlineFor(factors, band),
    factors: factors.map((f) => ({ ...f, score: Math.round(f.score) })),
    missing,
    weightsUsed: round(weightSum, 2),
    basis: 'เทียบกับค่าฐานของผู้ใช้เอง ไม่ใช่ค่ามาตรฐานประชากร',
  }
}

const BANDS = [
  { key: 'recover', max: 34, label: 'พักฟื้น', advice: 'วันนี้ควรพัก หรือขยับเบา ๆ เท่านั้น' },
  { key: 'caution', max: 54, label: 'ระวัง', advice: 'วันนี้เหมาะกับซ้อมเบาหรือพัก' },
  { key: 'ready', max: 79, label: 'พร้อม', advice: 'ซ้อมตามแผนได้' },
  { key: 'primed', max: 100, label: 'พร้อมมาก', advice: 'รับโหลดหนักได้' },
] as const

export const bandFor = (score: number) => BANDS.find((b) => score <= b.max) ?? BANDS[BANDS.length - 1]!

const REASONS: Record<FactorKey, (f: Factor) => string> = {
  hrv: (f) => `HRV ต่ำกว่าค่าฐาน ${f.deviation?.replace('−', '')}`,
  restingHeartRate: (f) => `ชีพจรพักสูงขึ้น ${f.deviation?.replace('+', '')}`,
  sleep: (f) => `นอน ${f.deviation} น้อยกว่าเป้า`,
  load: (f) => `โหลดการซ้อมสูงกว่าปกติ ${f.deviation}`,
}

/** The sentence is assembled from the worst factors, not written by a model. */
function headlineFor(factors: Factor[], band: (typeof BANDS)[number]): string {
  const concerning = factors
    .filter((f) => f.direction !== 'good')
    .sort((a, b) => a.score - b.score)
    .slice(0, 2)
  if (!concerning.length) return `ทุกค่าอยู่ในช่วงปกติ — ${band.advice}`
  return `${concerning.map((f) => REASONS[f.key](f)).join(' และ ')} — ${band.advice}`
}
