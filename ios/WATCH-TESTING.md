# Testing the watch hand-off on real hardware

Everything in phase 2 up to the watch's own screen has been verified on a paired
simulator. What remains can only be tested on the device. This is what to expect, what
can go wrong, and how to tell our bugs apart from Apple's.

Target hardware: **Apple Watch Series 5 on watchOS 10.6.2**, paired to an **iPhone on iOS 26.6.2**.

## Measured facts

Read from WorkoutKit itself (`WorkoutExport.probeCapabilities()`, run with `-watchProbe 1`),
not from documentation:

| | |
|---|---|
| `maxAllowedScheduledWorkoutCount` | **50** per app — we use 3, so the cap is not a concern |
| `supportsActivity(.running)` | true |
| Goal: open / time / distance | true |
| Goal: **energy** | **false** for running — do not use a calorie goal |
| Alert: `HeartRateRangeAlert` | true |
| Alert: `HeartRateZoneAlert` | true |
| Alert: `SpeedRangeAlert` `.current` and `.average` | true |
| Alert: `CadenceRangeAlert`, `PowerRangeAlert` | true |

`supportsAlert` answers whether **WorkoutKit** accepts the alert for this activity and
location. It does not know which watch is paired, so a `true` there is not a promise the
hardware can measure it. We only send heart-rate range and speed range, both of which a
Series 5 measures natively (optical heart rate + GPS). Running **power** needs Series 6 or
later, so that one would be accepted by the API and then do nothing on this watch —
another reason the alert policy sticks to heart rate and pace.

`SpeedThresholdAlert(target:metric:)` and `PowerRangeAlert(target:metric:)` need
iOS 17.4 / watchOS 10.4; the app's deployment target is iOS 17.0, so those overloads will
not compile. The plain `init(target:)` is fine at 17.0. We use neither.

## What should happen on the watch

From Apple's framework overview: scheduled workouts "appear in a dedicated space in the
Workout app and include your app's icon and name", and Apple's own sample says the planned
workout "appears **at the top of the Workout list** on the watch".

So: open **Workout** on the watch and look at the very top of the list for a Proxy Health
entry. It is not under Outdoor Run, and it is not in the iPhone Watch app.

Apple's sample also notes a workout must run **at least one minute** before the system
counts it complete.

## Before concluding anything is our bug

There is a long-running Apple defect with exactly this symptom: the workout is present in
`WorkoutScheduler.shared.scheduledWorkouts` on the phone and never appears on the watch.

- Reported from iOS 18.2 beta onward and still being reported in **April 2026**, with the
  specific note that it affects **iOS 26 paired with watchOS 10-11** while the same app
  works on iOS 18 with watchOS 10-11.
- That is this user's exact combination.
- Apple traced it to iCloud/Health account data rather than to any app: a brand-new Apple
  ID works, an existing one fails even after re-pairing, a clean install, or a new watch.
- Apple engineering acknowledged it in June 2025; fixes landed in iOS 26 beta 3 and
  regressed again in iOS 26.0.1.

Apple's own suggested mitigation is to remove everything and reschedule:

```swift
await WorkoutScheduler.shared.removeAllWorkouts()
await WorkoutScheduler.shared.schedule(plan, at: dateComponents)
```

The app already exposes this as **ตั้งค่า → ล้างแผนทั้งหมดจากนาฬิกา**, followed by a sync.

Sources:
- <https://developer.apple.com/forums/thread/767737>
- <https://developer.apple.com/documentation/workoutkit>
- <https://developer.apple.com/documentation/workoutkit/customizing-workouts-with-workoutkit>

## Test order

Run these in order; the first failure tells you where the problem is.

1. **Is a watch seen at all?** Calendar tab, "ครั้งต่อไป" card, bottom row. It must not say
   "ยังไม่พบ Apple Watch". If it does, the phone does not consider a watch paired and
   nothing else matters.
2. **Does authorisation succeed?** Tap ส่งเลย / อนุญาต. The system prompt is
   *Connect "Proxy Health"? … would like to add workouts to Apple Watch.*
3. **Does the phone think it sent?** The row flips to "อยู่บน Apple Watch แล้ว" and
   ตั้งค่า → Apple Watch shows a count of 3 (or however many sessions are planned).
4. **Does the watch show it?** Workout app, top of the list. **This is the step that has
   never been verified anywhere, and the step Apple's bug breaks.**
5. **Does the structure survive?** Start it: warmup → main → cooldown with the right
   durations, and the heart-rate ceiling alerting above the top of zone 2.
6. **Does the sweep work on device?** After finishing one, sync again: that day should
   leave the watch and the next planned session should take its slot.

If 1-3 pass and 4 fails, it is almost certainly the Apple defect, not us. Try the clear
button, then a sync, then give it several minutes — the original reporter noted the
workouts "took a long time to appear" even once working.

## What will not be there, by design

- **Step names in Thai.** `WorkoutStep.displayName` is watchOS 11; a Series 5 stops at
  watchOS 10.6.2, so the watch uses Apple's own stage names. The workout's overall name
  ("EASY · วิ่งเบา") does travel.
- **Stretch, drill and plyometrics steps**, and every `note` and `detail`. WorkoutKit has
  nowhere to put them; they stay in the app.
- **Rest and cross days.** Never sent.
- **No pace alert on easy and long runs.** Deliberate — heat moves easy pace legitimately,
  and the session is governed by the heart-rate ceiling.
