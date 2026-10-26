import Foundation

/// Where a sync has got to, and roughly how much longer it will take.
///
/// A full backfill walks 36 metrics over two years and takes minutes, so a spinner says far too
/// little. The phases below carry fixed weights — chosen from what a backfill actually spends
/// its time on — which keeps the bar monotonic even though the work inside each phase is only
/// known once the one before it has run.
public struct SyncProgress: Sendable, Equatable {
    public enum Phase: Int, Sendable, CaseIterable {
        case catalog, samples, workouts, hourly, daily, workoutDetail, finishing

        /// Share of the bar. Raw samples and daily statistics dominate a first sync; the rest
        /// are close to instant unless there is a backlog.
        public var weight: Double {
            switch self {
            case .catalog: 0.03
            case .samples: 0.42
            case .workouts: 0.03
            case .hourly: 0.10
            case .daily: 0.34
            case .workoutDetail: 0.06
            case .finishing: 0.02
            }
        }

        public var label: String {
            switch self {
            case .catalog: "ตรวจรายการข้อมูล"
            case .samples: "ดึงข้อมูลดิบ"
            case .workouts: "ออกกำลังกาย"
            case .hourly: "สรุปรายชั่วโมง"
            case .daily: "สรุปรายวัน"
            case .workoutDetail: "รายละเอียดการซ้อม"
            case .finishing: "กำลังปิดงาน"
            }
        }

        var startsAt: Double {
            Phase.allCases.prefix(while: { $0.rawValue < rawValue }).reduce(0) { $0 + $1.weight }
        }
    }

    public var phase: Phase
    /// Steps finished inside the phase, and how many there are. `total == 0` means the phase
    /// reports no steps of its own.
    public var done: Int
    public var total: Int
    /// What is being worked on right now — a metric key, a date — shown after the counter.
    public var detail: String?
    public var elapsed: TimeInterval

    public init(phase: Phase, done: Int = 0, total: Int = 0, detail: String? = nil, elapsed: TimeInterval = 0) {
        self.phase = phase
        self.done = done
        self.total = total
        self.detail = detail
        self.elapsed = elapsed
    }

    public var fraction: Double {
        let within = total > 0 ? min(1, Double(done) / Double(total)) : 0
        return min(1, phase.startsAt + phase.weight * within)
    }

    public var percent: Int { Int((fraction * 100).rounded()) }

    /// Estimated from the rate so far. Withheld early on, when a few fast metrics would promise
    /// a finish that the two-year daily pass is not going to keep.
    public var remaining: TimeInterval? {
        guard fraction >= 0.05, fraction < 1, elapsed >= 2 else { return nil }
        return elapsed * (1 - fraction) / fraction
    }

    /// "เหลืออีกประมาณ 2 นาที" — rounded, because a number to the second invites disbelief.
    public var remainingText: String? {
        guard let remaining else { return nil }
        if remaining < 20 { return "อีกไม่กี่วินาที" }
        if remaining < 90 { return "เหลืออีกประมาณ \(Int((remaining / 10).rounded()) * 10) วิ" }
        return "เหลืออีกประมาณ \(Int((remaining / 60).rounded())) นาที"
    }

    /// One line for the header: what is happening, how far in, and when it ends.
    public var line: String {
        var parts = [phase.label]
        if total > 0 { parts[0] += " \(min(done, total))/\(total)" }
        if let detail, !detail.isEmpty { parts.append(detail) }
        if let remainingText { parts.append(remainingText) }
        return parts.joined(separator: " · ")
    }
}
