import Foundation

/// Turning a planned session into something the watch can run, without importing WorkoutKit.
///
/// The translation is kept here, away from the SDK, because the parts that can be silently wrong
/// are arithmetic rather than API calls: pace inverts into speed, and the wrong alert on the
/// wrong kind of session is worse than no alert at all. Both are covered by tests;
/// `WorkoutExport` only turns the result of this into `CustomWorkout` values.
public enum WorkoutRecipe {

    // MARK: What the watch is asked to do

    /// Minutes or kilometres, or neither — "run until you press stop".
    public enum Goal: Equatable, Sendable {
        case open
        case minutes(Double)
        case kilometres(Double)
    }

    /// Heart rate in beats per minute, or speed in metres per second. Speed, not pace, because
    /// that is the only thing WorkoutKit takes.
    public enum Alert: Equatable, Sendable {
        case heartRate(ClosedRange<Int>)
        case speed(ClosedRange<Double>, average: Bool)
    }

    public struct Step: Equatable, Sendable {
        public var goal: Goal
        public var alert: Alert?
        public var name: String?

        public init(goal: Goal, alert: Alert? = nil, name: String? = nil) {
            self.goal = goal
            self.alert = alert
            self.name = name
        }
    }

    /// A run of steps, repeated. Recovery steps are marked so the watch shows them as such.
    public struct Block: Equatable, Sendable {
        public var steps: [(isRecovery: Bool, step: Step)]
        public var iterations: Int

        public init(steps: [(isRecovery: Bool, step: Step)], iterations: Int = 1) {
            self.steps = steps
            self.iterations = iterations
        }

        public static func == (a: Block, b: Block) -> Bool {
            a.iterations == b.iterations && a.steps.count == b.steps.count
                && zip(a.steps, b.steps).allSatisfy { $0.isRecovery == $1.isRecovery && $0.step == $1.step }
        }
    }

    public struct Recipe: Equatable, Sendable {
        public var displayName: String
        public var warmup: Step?
        public var blocks: [Block]
        public var cooldown: Step?
    }

    // MARK: Which metric is allowed to beep

    /// Chosen per kind of session, not per step. The rule behind every line: an alert that fires
    /// for something you cannot act on, or that pulls against the point of the session, costs
    /// more than silence.
    public enum Policy: Equatable, Sendable {
        /// Heart rate only, and in practice only the ceiling — see `heartRateBand`.
        case heartRateCeiling(Int)
        /// The pace the coach wrote for each step. `average` smooths a whole session; `current`
        /// is for sessions where you have to correct mid-rep.
        case pace(average: Bool)
        /// Pace on the work steps, nothing on the recovery steps.
        case paceOnWorkOnly
        /// No alert anywhere.
        case silent
        /// Not handed to the watch at all.
        case notSupported
    }

    /// A heart-rate ceiling has to be sent as a range: WorkoutKit has no
    /// `HeartRateThresholdAlert`, unlike speed, cadence and power. The floor is put far enough
    /// below the ceiling that it cannot fire for anyone running — the alert is a ceiling in
    /// intent, and a range only because the API has no other shape.
    public static let heartRateFloorOffset = 50

    public static func heartRateBand(ceiling: Int) -> ClosedRange<Int> {
        max(60, ceiling - heartRateFloorOffset)...ceiling
    }

    /// `zoneCeiling` is the top of zone 2 — where zone 3 begins — read from the user's own
    /// zones rather than Apple's.
    ///
    /// - easy: the ceiling as it stands. Drifting up is the only way to get an easy run wrong.
    /// - long: five beats higher. Past an hour, heart rate climbs at an unchanged effort
    ///   (cardiac drift), and an easy-run ceiling would beep for that rather than for effort.
    /// - marathon: the session rehearses a pace, judged over the whole session.
    /// - threshold: pace again, but current — knowing at the end is no use.
    /// - interval: pace on the work only. Heart rate trails effort by 60-90 seconds, so a
    ///   two-minute rep ends before the reading arrives.
    /// - repetition: nothing. A 20-40 second rep is over before feedback can be acted on.
    public static func policy(for type: String, zoneCeiling: Int?) -> Policy {
        switch type {
        case "easy":
            return zoneCeiling.map { .heartRateCeiling($0) } ?? .silent
        case "long":
            return zoneCeiling.map { .heartRateCeiling($0 + 5) } ?? .silent
        case "marathon":
            return .pace(average: true)
        case "threshold":
            return .pace(average: false)
        case "interval":
            return .paceOnWorkOnly
        case "repetition":
            return .silent
        default:
            // rest, cross, and anything a later server version adds.
            return .notSupported
        }
    }

    // MARK: Pace

    /// Seconds per kilometre to metres per second.
    ///
    /// The range inverts: 7:14/km (434s) is *faster* than 7:55/km (475s), so it becomes the
    /// *upper* speed bound. Getting this backwards produces a reversed range, which is either a
    /// crash or an alert that fires constantly, and neither announces itself.
    public static func speedRange(paceSecPerKm: [Int]?) -> ClosedRange<Double>? {
        guard let pace = paceSecPerKm, pace.count == 2 else { return nil }
        let fastest = min(pace[0], pace[1])
        let slowest = max(pace[0], pace[1])
        guard fastest > 0, slowest > 0 else { return nil }
        let lower = 1000.0 / Double(slowest)
        let upper = 1000.0 / Double(fastest)
        guard lower <= upper else { return nil }
        return lower...upper
    }

    // MARK: Building

    /// Phases the watch has nowhere to put. Dropped rather than flattened into a timed step,
    /// which would have the watch counting down a stretch as though it were a run.
    static let droppedPhases: Set<String> = ["stretch", "drill", "plyometrics"]

    /// Builds the recipe, or returns nil when the day is not something the watch should carry.
    ///
    /// - Parameters:
    ///   - type: the plan's session type.
    ///   - steps: the plan's steps, in order.
    ///   - repeats: `reps.count`, when the session is interval work.
    ///   - zoneCeiling: the top of the user's zone 2, in bpm.
    public static func build(
        type: String,
        displayName: String,
        steps: [PlannedStep],
        repeats: Int? = nil,
        zoneCeiling: Int?
    ) -> Recipe? {
        let policy = policy(for: type, zoneCeiling: zoneCeiling)
        if policy == .notSupported { return nil }

        let usable = steps.filter { !droppedPhases.contains($0.phase) }
        guard !usable.isEmpty else { return nil }

        let warmup = usable.first { $0.phase == "warmup" }
        let cooldown = usable.last { $0.phase == "cooldown" }
        let middle = usable.filter { $0.phase != "warmup" && $0.phase != "cooldown" }
        guard !middle.isEmpty else { return nil }

        // Repeated work is one block run N times; anything else is a block per step, so the
        // watch still shows them as separate stages.
        let iterations = max(1, repeats ?? 1)
        let body = middle.map { (isRecovery: $0.phase == "recovery", step: step(from: $0, policy: policy)) }
        let blocks = iterations > 1
            ? [Block(steps: body, iterations: iterations)]
            : body.map { Block(steps: [$0], iterations: 1) }

        return Recipe(
            displayName: displayName,
            warmup: warmup.map { step(from: $0, policy: .silent) },
            blocks: blocks,
            cooldown: cooldown.map { step(from: $0, policy: .silent) }
        )
    }

    /// The warmup and cooldown are always silent regardless of policy: a heart-rate floor would
    /// fire for the whole warmup, which is exactly when being under it is correct.
    static func step(from planned: PlannedStep, policy: Policy) -> Step {
        Step(goal: goal(from: planned), alert: alert(for: planned, policy: policy), name: planned.name)
    }

    static func goal(from planned: PlannedStep) -> Goal {
        if let minutes = planned.minutes, minutes > 0 { return .minutes(minutes) }
        if let km = planned.distanceKm, km > 0 { return .kilometres(km) }
        return .open
    }

    static func alert(for planned: PlannedStep, policy: Policy) -> Alert? {
        switch policy {
        case .heartRateCeiling(let ceiling):
            return .heartRate(heartRateBand(ceiling: ceiling))
        case .pace(let average):
            return speedRange(paceSecPerKm: planned.paceSecPerKm).map { .speed($0, average: average) }
        case .paceOnWorkOnly:
            guard planned.phase != "recovery" else { return nil }
            return speedRange(paceSecPerKm: planned.paceSecPerKm).map { .speed($0, average: false) }
        case .silent, .notSupported:
            return nil
        }
    }

    /// The plan's own step, flattened to what the translation needs. Keeps this file free of the
    /// app's `Codable` models, which drag in the rest of the server shapes.
    public struct PlannedStep: Equatable, Sendable {
        public var phase: String
        public var minutes: Double?
        public var distanceKm: Double?
        public var paceSecPerKm: [Int]?
        public var name: String?

        public init(
            phase: String, minutes: Double? = nil, distanceKm: Double? = nil,
            paceSecPerKm: [Int]? = nil, name: String? = nil
        ) {
            self.phase = phase
            self.minutes = minutes
            self.distanceKm = distanceKm
            self.paceSecPerKm = paceSecPerKm
            self.name = name
        }
    }
}
