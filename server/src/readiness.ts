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
  /** Minutes in bed, which is the figure people remember; shown for context, never scored.
   *  Only worth showing when it is meaningfully longer than the time asleep — this watch
   *  sometimes reports the two as the same number, and "6:28/6:28" tells a reader nothing. */
  inBedMinutes?: number
  /** Exercise minutes per day: the recent average against the long-run average. */
  load?: { acute: number; chronic: number }
  /** The windows those averages were taken over, which the chronic one grows into. */
  loadWindows?: { acuteDays: number; chronicDays: number; historyDays: number }
  /** Target night's sleep in minutes. */
  sleepTargetMinutes?: number
  /** When the night ended, in ISO. Not scored — it is the anchor the day's score is tied to. */
  wakeTime?: string
  /** Whether `hrv` came from readings taken while asleep or from Apple's daily average. */
  hrvSource?: 'sleep' | 'daily'
  /** Nights of sleeping HRV available, which is what decides the source above. */
  hrvNights?: number
  /** Nights the current figure is taken over, since one night of it is mostly noise. */
  hrvRecentNights?: number
  /** Last night on its own, for a reader who wants to see what the smoothing covered. */
  hrvLastNight?: number
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
  /** The same gap as a percentage, which is what the card shows in brackets. */
  changePercent?: number
  /** Extra context for the row; sleep uses it for time in bed. */
  note?: string
  /** Shown next to the value in a lighter colour: sleep puts time in bed here, so the card
   *  reads "5:04/7:09" without needing to know what the note means. */
  secondary?: string
  /** Where the number came from, when there is more than one possible source. */
  source?: 'sleep' | 'daily'
  direction: 'good' | 'watch' | 'bad'
}

const WEIGHTS: Record<FactorKey, number> = {
  hrv: 0.3,
  restingHeartRate: 0.25,
  sleep: 0.3,
  load: 0.15,
}

const SLEEP_TARGET_MINUTES = 480
/** Below this, time in bed and time asleep are the same story told twice. */
const MEANINGFUL_BED_GAP_MINUTES = 10
/** Below two factors the number would be more noise than signal. */
const MINIMUM_FACTORS = 2

const clock = (minutes: number) => `${Math.floor(minutes / 60)}:${String(Math.round(minutes % 60)).padStart(2, '0')}`
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
      source: inputs.hrvSource,
      note:
        inputs.hrvSource === 'sleep' && inputs.hrvRecentNights
          ? `ค่ากลางตอนหลับ ${inputs.hrvRecentNights} คืน${inputs.hrvLastNight !== undefined ? ` · เมื่อคืน ${round(inputs.hrvLastNight)}` : ''}`
          : undefined,
      deviation: `${percent >= 0 ? '+' : '−'}${Math.abs(round(percent, 0))}%`,
      changePercent: round(percent, 0),
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
      changePercent: round((delta / inputs.restingHeartRate.baseline) * 100, 0),
      direction: delta <= 2 ? 'good' : delta <= 5 ? 'watch' : 'bad',
    })
  } else {
    missing.push('restingHeartRate')
  }

  // Sleep: straight proportion of the target, so eight hours is full marks.
  if (inputs.sleepMinutes !== undefined) {
    const inBed =
      inputs.inBedMinutes !== undefined && inputs.inBedMinutes - inputs.sleepMinutes >= MEANINGFUL_BED_GAP_MINUTES
        ? inputs.inBedMinutes
        : undefined
    const target = inputs.sleepTargetMinutes ?? SLEEP_TARGET_MINUTES
    const ratio = inputs.sleepMinutes / target
    factors.push({
      key: 'sleep',
      score: clamp(ratio * 100),
      weight: WEIGHTS.sleep,
      value: Math.round(inputs.sleepMinutes),
      baseline: target,
      deviation: `${Math.floor(inputs.sleepMinutes / 60)}:${String(Math.round(inputs.sleepMinutes % 60)).padStart(2, '0')}`,
      // Scored on time asleep — the recovery signal — while the remembered figure is usually
      // time in bed, so the gap is shown rather than left to look like an error.
      changePercent: round((ratio - 1) * 100, 0),
      note: inBed !== undefined ? `บนเตียง ${clock(inBed)}` : undefined,
      secondary: inBed !== undefined ? clock(inBed) : undefined,
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
      changePercent: round((ratio - 1) * 100, 0),
      note: inputs.loadWindows
        ? `เฉลี่ย ${inputs.loadWindows.acuteDays} วันล่าสุด เทียบ ${inputs.loadWindows.chronicDays} วัน`
        : undefined,
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

  const reason = reasonFor(factors)
  return {
    score,
    band: band.key,
    bandLabel: band.label,
    advice: band.advice,
    /** The two parts separately, so a view can lay them out on their own lines. */
    reason,
    headline: reason ? `${reason} — ${band.advice}` : `ทุกค่าอยู่ในช่วงปกติ — ${band.advice}`,
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

/** Assembled from the worst factors, not written by a model. Empty when nothing stands out. */
function reasonFor(factors: Factor[]): string {
  const concerning = factors
    .filter((f) => f.direction !== 'good')
    .sort((a, b) => a.score - b.score)
    .slice(0, 2)
  return concerning.map((f) => REASONS[f.key](f)).join(' และ ')
}

/**
 * Whether the score can be frozen for the day. Readiness answers "how recovered did this morning
 * start", so recomputing it at lunchtime with a fresh pulse reading changes the answer to a
 * question nobody asked. It is locked as soon as the three measured factors are in; load is not
 * waited for, since a day with no exercise history would never complete.
 */
export const READINESS_LOCK_HOUR = 12

export function readinessIsComplete(missing: string[]) {
  return !missing.some((key) => key === 'hrv' || key === 'restingHeartRate' || key === 'sleep')
}

export function shouldLockReadiness(missing: string[], localHour: number) {
  return readinessIsComplete(missing) || localHour >= READINESS_LOCK_HOUR
}
