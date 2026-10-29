import Foundation
import HealthKit
import WorkoutKit

/// Puts the next few planned sessions onto the watch, and — the part that actually matters —
/// takes them off again.
///
/// WorkoutKit caps how many workouts may be scheduled at once and promises no automatic
/// clean-up: `markComplete`, `remove` and `removeAllWorkouts` are all ours to call. So the rule
/// here is sweep first, then send, on every sync. If watchOS turns out to clear something
/// itself, the sweep simply finds nothing — it is safe either way.
///
/// Whether a session happened is not guessed here. `/v1/plan` already decides `outcome` per day,
/// which is what phase 1 computed it server-side for.
@MainActor
enum WorkoutExport {
    /// How many sessions the watch holds. Counted in sessions rather than days: rest days are
    /// never sent, so three covers roughly a week while using exactly three slots however dense
    /// the plan is — under the cap by construction rather than by luck.
    static let sessionsAhead = 3

    static var isSupported: Bool { WorkoutScheduler.isSupported }

    static var authorization: WorkoutScheduler.AuthorizationState {
        get async { await WorkoutScheduler.shared.authorizationState }
    }

    @discardableResult
    static func requestAuthorization() async -> WorkoutScheduler.AuthorizationState {
        await WorkoutScheduler.shared.requestAuthorization()
    }

    // MARK: Reconcile

    struct Outcome {
        var scheduled: [String] = []
        var removed: [String] = []
        var skipped: [String] = []
        /// Set when the watch refused or is unavailable, so the UI can say why rather than
        /// silently showing nothing.
        var unavailable: String?
    }

    /// Brings the watch in line with the plan: clears what is done or past, replaces what the
    /// coach has rewritten, and tops up to `sessionsAhead`.
    static func reconcile(plan: PlanRangeDoc, zones: ZonesDoc?, startHour: Int, startMinute: Int) async -> Outcome {
        var outcome = Outcome()
        guard WorkoutScheduler.isSupported else {
            outcome.unavailable = "เครื่องนี้ส่งแผนเข้านาฬิกาไม่ได้"
            return outcome
        }
        guard await authorization == .authorized else {
            outcome.unavailable = "ยังไม่ได้อนุญาตให้ส่งแผนเข้านาฬิกา"
            return outcome
        }

        let wanted = upcoming(in: plan)
        let wantedDates = Set(wanted.map(\.date))
        let existing = await WorkoutScheduler.shared.scheduledWorkouts

        // Sweep. Anything not in the window goes, whether it was done, missed, or belongs to a
        // plan the coach has since rewritten — in every one of those cases keeping it would
        // leave the watch showing something the calendar no longer says.
        for entry in existing {
            guard let date = dayKey(from: entry.date) else { continue }
            guard !wantedDates.contains(date) else { continue }
            if finished(date: date, in: plan) {
                await WorkoutScheduler.shared.markComplete(entry.plan, at: entry.date)
            }
            await WorkoutScheduler.shared.remove(entry.plan, at: entry.date)
            outcome.removed.append(date)
        }

        let stillThere = Set((await WorkoutScheduler.shared.scheduledWorkouts).compactMap { dayKey(from: $0.date) })
        for day in wanted {
            guard !stillThere.contains(day.date) else { continue }
            guard let workout = customWorkout(for: day, zones: zones) else {
                outcome.skipped.append(day.date)
                continue
            }
            var when = components(for: day.date)
            when.hour = startHour
            when.minute = startMinute
            await WorkoutScheduler.shared.schedule(WorkoutPlan(.custom(workout)), at: when)
            outcome.scheduled.append(day.date)
        }
        return outcome
    }

    /// Clears the watch completely. The plan in the calendar is untouched, and the next sync
    /// fills the watch again — which is what makes this safe to offer as a reset.
    static func removeAll() async {
        guard WorkoutScheduler.isSupported else { return }
        await WorkoutScheduler.shared.removeAllWorkouts()
    }

    static func scheduledDates() async -> [String] {
        guard WorkoutScheduler.isSupported, await authorization == .authorized else { return [] }
        return (await WorkoutScheduler.shared.scheduledWorkouts)
            .compactMap { dayKey(from: $0.date) }
            .sorted()
    }

    // MARK: What belongs on the watch

    /// The next `sessionsAhead` days from today that carry a session the watch can run. Rest and
    /// cross days are passed over rather than counted.
    static func upcoming(in plan: PlanRangeDoc) -> [PlanDayDoc] {
        plan.days
            .filter { $0.date >= plan.today && $0.plan != nil && $0.state == .planned }
            .filter { WorkoutRecipe.policy(for: $0.plan?.type ?? "", zoneCeiling: nil) != .notSupported }
            .prefix(sessionsAhead)
            .map { $0 }
    }

    /// Whether the server says that day's session happened — `done` or `different` both mean a
    /// workout was recorded, which is all `markComplete` is claiming.
    static func finished(date: String, in plan: PlanRangeDoc) -> Bool {
        guard let day = plan.days.first(where: { $0.date == date }) else { return false }
        return day.state == .done || day.state == .different
    }

    // MARK: Translation

    static func customWorkout(for day: PlanDayDoc, zones: ZonesDoc?) -> CustomWorkout? {
        guard let planned = day.plan else { return nil }
        let steps = (planned.steps ?? []).map {
            WorkoutRecipe.PlannedStep(
                phase: $0.phase,
                minutes: $0.minutes,
                distanceKm: $0.distanceKm,
                paceSecPerKm: $0.paceSecPerKm,
                name: $0.phaseLabel
            )
        }
        guard let recipe = WorkoutRecipe.build(
            type: planned.type,
            displayName: "\(planned.kind.short) · \(planned.kind.title)",
            steps: steps,
            repeats: planned.reps?.count,
            zoneCeiling: zoneCeiling(zones)
        ) else { return nil }

        let activity = HKWorkoutActivityType.running
        let location = HKWorkoutSessionLocationType.outdoor
        return CustomWorkout(
            activity: activity,
            location: location,
            displayName: recipe.displayName,
            warmup: recipe.warmup.map { step($0, activity: activity, location: location) },
            blocks: recipe.blocks.map { block in
                IntervalBlock(
                    steps: block.steps.map {
                        IntervalStep(
                            $0.isRecovery ? .recovery : .work,
                            step: step($0.step, activity: activity, location: location)
                        )
                    },
                    iterations: block.iterations
                )
            },
            cooldown: recipe.cooldown.map { step($0, activity: activity, location: location) }
        )
    }

    /// The top of zone 2 — where zone 3 begins. Taken from the user's own corroborated maximum,
    /// not `HeartRateZoneAlert`, whose zone 2 is Apple's own estimate and need not agree.
    static func zoneCeiling(_ zones: ZonesDoc?) -> Int? {
        zones?.zones.first { $0.zone == 2 }?.to
    }

    private static func step(
        _ recipe: WorkoutRecipe.Step,
        activity: HKWorkoutActivityType,
        location: HKWorkoutSessionLocationType
    ) -> WorkoutStep {
        var step = WorkoutStep(goal: goal(recipe.goal))
        // An alert the watch cannot honour costs the alert, not the whole workout.
        if let alert = alert(recipe.alert),
           CustomWorkout.supportsAlert(alert, activity: activity, location: location) {
            step.alert = alert
        }
        // `WorkoutStep.displayName` is watchOS 11, and a Series 5 stops at 10.6.1, so a per-step
        // name could never reach this user's watch. The Workout app labels the stages itself;
        // only the workout's own name carries across. `Step.name` is kept for the app's own UI.
        return step
    }

    private static func goal(_ goal: WorkoutRecipe.Goal) -> WorkoutGoal {
        switch goal {
        case .open: .open
        case .minutes(let minutes): .time(minutes, .minutes)
        case .kilometres(let km): .distance(km, .kilometers)
        }
    }

    private static func alert(_ alert: WorkoutRecipe.Alert?) -> (any WorkoutAlert)? {
        switch alert {
        case .heartRate(let band):
            let low = Measurement(value: Double(band.lowerBound), unit: UnitFrequency.beatsPerMinute)
            let high = Measurement(value: Double(band.upperBound), unit: UnitFrequency.beatsPerMinute)
            return HeartRateRangeAlert(target: low...high)
        case .speed(let range, let average):
            let low = Measurement(value: range.lowerBound, unit: UnitSpeed.metersPerSecond)
            let high = Measurement(value: range.upperBound, unit: UnitSpeed.metersPerSecond)
            return SpeedRangeAlert(target: low...high, metric: average ? .average : .current)
        case nil:
            return nil
        }
    }

    // MARK: Dates

    /// The scheduler works in `DateComponents`, and the plan in `yyyy-MM-dd`.
    static func components(for date: String) -> DateComponents {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return DateComponents() }
        return DateComponents(year: parts[0], month: parts[1], day: parts[2])
    }

    static func dayKey(from components: DateComponents) -> String? {
        guard let year = components.year, let month = components.month, let day = components.day
        else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}

extension UnitFrequency {
    /// WorkoutKit takes heart rate as a frequency, and Foundation has no per-minute unit.
    static let beatsPerMinute = UnitFrequency(symbol: "bpm", converter: UnitConverterLinear(coefficient: 1.0 / 60.0))
}
