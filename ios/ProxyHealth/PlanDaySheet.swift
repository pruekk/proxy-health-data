import SwiftUI

/// What one day was: the plan written for it, what was recorded against it, and the one line
/// that says how the two compare. A day that has been and gone shows no way to change it —
/// the server refuses the write anyway, and an affordance that always fails is worse than none.
struct PlanDaySheet: View {
    let day: PlanDayDoc
    /// The server's local date, which decides whether this day is past, present or future.
    let today: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    heading
                    if let plan = day.plan {
                        label("แผนของวันนั้น").padding(.top, 18)
                        Card { PlanPrescription(plan: plan) }.padding(.top, 8)
                    }
                    actualSection
                    verdict
                    footnote
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 32)
            }
            .background(Brand.ground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("เสร็จ") { dismiss() } }
            }
        }
    }

    // MARK: Heading

    private var heading: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(PlanFormat.dayLabel(day.date, long: true))
                .font(.system(size: 22, weight: .bold))
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 10)
    }

    private var subtitle: String {
        if let kind = day.plan?.kind {
            return "\(kind.title) · \(kind.purpose)"
        }
        switch day.state {
        case .unplanned: return "ออกกำลังกายโดยไม่ได้วางแผนไว้"
        default: return "ไม่มีแผนและไม่มีการออกกำลังกาย"
        }
    }

    // MARK: What happened

    @ViewBuilder private var actualSection: some View {
        if !day.workouts.isEmpty {
            label("ที่ทำจริง").padding(.top, 20)
            Card(vertical: 3) {
                ForEach(day.workouts) { workout in
                    MetricRow(
                        symbol: "figure.run",
                        title: title(workout),
                        subtitle: timing(workout),
                        value: workout.minutes.map { $0.formatted(0) } ?? "—",
                        detail: "นาที",
                        tint: Brand.blue
                    )
                    if workout.avgHeartRate != nil || workout.maxHeartRate != nil {
                        MetricRow(
                            symbol: "heart.fill",
                            title: "ชีพจรเฉลี่ย / สูงสุด",
                            value: heartRate(workout),
                            tint: Brand.move
                        )
                    }
                }
            }
            .padding(.top, 8)
        } else if day.date < today, day.plan != nil {
            label("ที่ทำจริง").padding(.top, 20)
            Card {
                Text(day.plan?.kind == .rest ? "พักตามแผน" : "ไม่มีการออกกำลังกายบันทึกไว้")
                    .font(.system(size: 14, weight: .semibold))
            }
            .padding(.top, 8)
        }
    }

    private func title(_ workout: PlanActualDoc) -> String {
        let name = workout.activityTypeName ?? "ออกกำลังกาย"
        guard let km = workout.distanceKm, km > 0 else { return name }
        return "\(name) · \(km.formatted(2)) กม."
    }

    private func timing(_ workout: PlanActualDoc) -> String? {
        guard let startLocal = workout.startLocal else { return nil }
        // The server writes the local wall clock as "2026-10-24 18:05"; the time is the only
        // part worth showing here, since the date is already the sheet's title.
        guard let time = startLocal.split(separator: " ").last else { return nil }
        return "เริ่ม \(time) น."
    }

    private func heartRate(_ workout: PlanActualDoc) -> String {
        let avg = workout.avgHeartRate.map { $0.formatted(0) } ?? "—"
        let max = workout.maxHeartRate.map { $0.formatted(0) } ?? "—"
        return "\(avg) / \(max)"
    }

    // MARK: How the two compare

    @ViewBuilder private var verdict: some View {
        if let text = verdictText {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: verdictSymbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(verdictTint)
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.top, 18)
            .padding(.horizontal, 2)
        }
    }

    private var verdictText: String? {
        switch day.state {
        case .done:
            return day.harder == true
                ? "ทำตามแผน แต่หนักกว่าที่วางไว้ — เทียบกับช่วงเป้าหมายแล้วเร็วหรือชีพจรสูงกว่า"
                : "ทำตามแผน"
        case .different:
            return "ทำคนละแบบกับแผน — แผนคือ \(day.plan?.kind.title ?? "—") แต่ที่บันทึกไว้เป็นคนละอย่าง ไม่ได้แปลว่าผิด"
        case .missed:
            return "ไม่มีการออกกำลังกายในวันนี้ แผนยังอยู่เพื่อให้เทียบได้ว่าตั้งใจทำอะไร"
        case .rest:
            return "พักตามแผน"
        case .unplanned:
            return "ไม่มีแผนไว้ล่วงหน้า"
        case .planned:
            return day.date == today
                ? "แผนของวันนี้ยังแก้ได้จนกว่าจะมีการออกกำลังกายบันทึกเข้ามา"
                : nil
        case .none:
            return nil
        }
    }

    private var verdictSymbol: String {
        switch day.state {
        case .done: day.harder == true ? "flame.fill" : "checkmark.circle.fill"
        case .different: "arrow.left.arrow.right"
        case .missed: "circle.dashed"
        case .rest: "moon.zzz.fill"
        default: "info.circle"
        }
    }

    private var verdictTint: Color {
        switch day.state {
        case .done: day.harder == true ? PlanPalette.harder : .green
        case .missed: Color(.tertiaryLabel)
        default: .secondary
        }
    }

    @ViewBuilder private var footnote: some View {
        if day.date < today {
            Text("แผนของวันที่ผ่านไปแล้วแก้ไม่ได้ — เก็บไว้เพื่อเทียบว่าตั้งใจทำอะไรกับได้อะไรจริง")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .padding(.top, 18)
                .padding(.horizontal, 2)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold))
            .kerning(0.9)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
    }
}
