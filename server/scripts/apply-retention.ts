// One-off: stamps `expiresAt` on documents written before retention existed, using the same
// rules as ingest. Run it AFTER deploying and BEFORE enabling the TTL policies, so nothing is
// swept with the wrong date.
//
//   bun scripts/apply-retention.ts <uid> [--apply]
//
// Without --apply it only reports what it would do.
//
// The tricky part is raw samples from high-frequency metrics: those keep a short window unless
// they were recorded during a workout, and documents uploaded before this change carry no
// `context` field. Workout intervals are therefore reconstructed and matched here.

import { Timestamp } from 'firebase-admin/firestore'
import { catalog } from '../src/catalog'
import { db } from '../src/firebase'
import { DEFAULT_RETENTION_YEARS, getRetentionYears } from '../src/store'

const uid = process.argv[2]
const apply = process.argv.includes('--apply')
if (!uid) {
  console.error('usage: bun scripts/apply-retention.ts <uid> [--apply]')
  process.exit(1)
}

const SHORT = new Set(catalog.quantities.filter((q) => q.retention === 'short').map((q) => q.key))
const shortMs = catalog.sync.shortRetentionDays * 86_400_000

const user = db.collection('users').doc(uid)
const years = (await getRetentionYears(uid)) ?? DEFAULT_RETENTION_YEARS
const longMs = years * 365.25 * 86_400_000
console.log(`retention: ${years} year(s); short window: ${catalog.sync.shortRetentionDays} days`)

// Workout intervals, padded by the recovery tail the detail sync uses.
const workouts = await user.collection('workouts').get()
const intervals = workouts.docs
  .map((d) => ({
    from: (d.get('startDate') as Timestamp).toMillis(),
    to: (d.get('endDate') as Timestamp).toMillis() + catalog.sync.recoveryTailSeconds * 1000,
  }))
  .sort((a, b) => a.from - b.from)
console.log(`workouts: ${intervals.length}`)

const inWorkout = (at: number) => intervals.some((i) => at >= i.from && at <= i.to)

let scanned = 0
let stamped = 0
const writer = db.bulkWriter()

for (const metric of await user.collection('metrics').listDocuments()) {
  const type = metric.id
  const short = SHORT.has(type)
  const samples = await metric.collection('samples').get()
  for (const doc of samples.docs) {
    scanned += 1
    if (doc.get('expiresAt')) continue
    const startDate = doc.get('startDate') as Timestamp | undefined
    if (!startDate) continue
    const at = startDate.toMillis()
    const keepLong = !short || doc.get('context') === 'workout' || inWorkout(at)
    const expiresAt = Timestamp.fromMillis(at + (keepLong ? longMs : shortMs))
    stamped += 1
    if (apply) writer.set(doc.ref, { expiresAt }, { merge: true })
  }
  console.log(`  ${type.padEnd(30)} ${samples.size} samples${short ? ' (short window)' : ''}`)
}

// Daily, hourly and workout documents all follow the single retention value.
for (const [name, dateField] of [
  ['daily', null],
  ['hourly', null],
  ['workouts', 'startDate'],
] as const) {
  const snap = await user.collection(name).get()
  for (const doc of snap.docs) {
    scanned += 1
    if (doc.get('expiresAt')) continue
    const base = dateField
      ? (doc.get(dateField) as Timestamp).toMillis()
      : new Date(`${doc.id}T00:00:00Z`).getTime()
    if (!Number.isFinite(base)) continue
    stamped += 1
    if (apply) writer.set(doc.ref, { expiresAt: Timestamp.fromMillis(base + longMs) }, { merge: true })
  }
  console.log(`  ${name.padEnd(30)} ${snap.size} documents`)
}

if (apply) await writer.close()
console.log(`\nscanned ${scanned}, ${apply ? 'stamped' : 'would stamp'} ${stamped}`)
if (!apply) console.log('dry run — pass --apply to write')
