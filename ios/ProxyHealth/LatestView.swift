import SwiftUI

/// Tab one: where things stand right now. Slow-moving values carry the date they were measured,
/// because a weight from nine days ago means something different from this morning's.
struct LatestView: View {
    @Environment(AppModel.self) private var model
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                header
                rings
                todayTiles
                body_
                heart
                fitness
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 110)
        }
        .background(Brand.ground)
        .refreshable { await model.syncNow(trigger: .manual); await dashboard.load(settings: model.settings, force: true) }
        .task { await dashboard.load(settings: model.settings) }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("วันนี้").font(.system(size: 24, weight: .bold))
                Text(syncLine).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task {
                    await model.syncNow(trigger: .manual)
                    await dashboard.load(settings: model.settings, force: true)
                }
            } label: {
                Group {
                    // `.symbolEffect(.rotate:)` needs iOS 18; the deployment target is 17.
                    if model.isSyncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .semibold))
                    }
                }
                .foregroundStyle(Brand.blue)
                .frame(width: 34, height: 34)
                .background(Brand.card, in: Circle())
                .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
            }
            .disabled(model.isSyncing)
        }
        .padding(.top, 8)
    }

    private var syncLine: String {
        // Falls back to the server's own history, so a fresh install still shows when the data
        // was last updated rather than claiming it never synced.
        guard let at = model.lastSyncAt ?? dashboard.syncs.first?.startedAt else { return "ยังไม่เคยซิงก์" }
        return "ซิงก์เมื่อ \(at.relativeThai)"
    }

    private var rings: some View {
        Card {
            HStack(spacing: 0) {
                let activity = dashboard.today?.activity
                Ring(value: activity?.activeEnergyKcal ?? 0, goal: activity?.activeEnergyGoalKcal ?? 0,
                     color: Brand.move, name: "เคลื่อนไหว",
                     detail: "\((activity?.activeEnergyKcal ?? 0).formatted(0)) / \((activity?.activeEnergyGoalKcal ?? 0).formatted(0)) kcal")
                Ring(value: activity?.exerciseMinutes ?? 0, goal: activity?.exerciseMinutesGoal ?? 30,
                     color: Brand.exercise, name: "ออกกำลัง",
                     detail: "\((activity?.exerciseMinutes ?? 0).formatted(0)) / \((activity?.exerciseMinutesGoal ?? 30).formatted(0)) นาที")
                Ring(value: activity?.standHours ?? 0, goal: activity?.standHoursGoal ?? 12,
                     color: Brand.stand, name: "ยืน",
                     detail: "\((activity?.standHours ?? 0).formatted(0)) / \((activity?.standHoursGoal ?? 12).formatted(0)) ชม.")
            }
        }
    }

    private var todayTiles: some View {
        HStack(spacing: 12) {
            Tile(label: "ก้าว",
                 value: (dashboard.today?.value("stepCount") ?? 0).formatted(0),
                 meta: dashboard.average("stepCount", lastDays: 7).map { "เฉลี่ย 7 วัน \($0.formatted(0))" },
                 symbol: "figure.walk", tint: Brand.move)
            Tile(label: "ชีพจรพัก",
                 value: (dashboard.metric("restingHeartRate")?.value ?? 0).formatted(0),
                 unit: "bpm",
                 meta: dashboard.average("restingHeartRate", lastDays: 30).map { "เฉลี่ย 30 วัน \($0.formatted(0))" },
                 symbol: "heart", tint: .pink)
        }
    }

    private var body_: some View {
        VStack(spacing: 0) {
            SectionTitle(text: "ร่างกาย", hint: bodyMeasuredHint)
            Card {
                VStack(spacing: 0) {
                    row("bodyMass", "scalemass", "น้ำหนัก", unit: "kg", decimals: 1)
                    Divider()
                    row("height", "figure.stand", "ส่วนสูง", unit: "m", decimals: 2)
                    Divider()
                    row("bodyMassIndex", "circle.dashed", "BMI", unit: nil, decimals: 1)
                    Divider()
                    row("bodyFatPercentage", "drop", "ไขมัน", unit: "%", decimals: 1, scale: 100)
                    Divider()
                    row("leanBodyMass", "figure.arms.open", "มวลไร้ไขมัน", unit: "kg", decimals: 1)
                    Divider()
                    row("waistCircumference", "ruler", "รอบเอว", unit: "cm", decimals: 1)
                }
            }
        }
    }

    private var bodyMeasuredHint: String? {
        guard let at = dashboard.metric("bodyMass")?.measuredAt else { return nil }
        return "วัดล่าสุด \(at.relativeThai)"
    }

    private func row(_ type: String, _ symbol: String, _ title: String, unit: String?, decimals: Int, scale: Double = 1) -> some View {
        let metric = dashboard.metric(type)
        let value = metric?.value.map { ($0 * scale).formatted(decimals) } ?? "—"
        var detail: String?
        var style = MetricRow.DetailStyle.plain
        if metric?.value == nil {
            detail = "ยังไม่มีข้อมูล"
        } else if let change = dashboard.change(type), abs(change.delta) > 0.05 {
            let sign = change.delta > 0 ? "+" : "−"
            detail = "\(sign)\(abs(change.delta * scale).formatted(1)) / \(change.days) วัน"
            // Down is the wanted direction for weight and fat, up for lean mass.
            let lowerIsBetter = type != "leanBodyMass" && type != "height"
            style = (change.delta < 0) == lowerIsBetter ? .good : .bad
        } else if let at = metric?.measuredAt {
            detail = at.relativeThai
        }
        var subtitle: String?
        if let count = metric?.sampleCount, count > 0 {
            subtitle = "\(count) ครั้งที่บันทึก"
        } else if let at = metric?.measuredAt {
            subtitle = "วัดเมื่อ \(at.relativeThai)"
        }
        return MetricRow(symbol: symbol, title: title, subtitle: subtitle,
                         value: unit == nil ? value : "\(value) \(unit!)", detail: detail, detailStyle: style)
    }

    private var heart: some View {
        VStack(spacing: 0) {
            SectionTitle(text: "หัวใจและการหายใจ")
            HStack(spacing: 12) {
                Tile(label: "HRV", value: (dashboard.metric("heartRateVariabilitySDNN")?.value ?? 0).formatted(1), unit: "ms",
                     meta: dashboard.average("heartRateVariabilitySDNN", lastDays: 30).map { "เฉลี่ย 30 วัน \($0.formatted(1))" })
                Tile(label: "หายใจ", value: (dashboard.metric("respiratoryRate")?.value ?? 0).formatted(1), unit: "/นาที")
            }
            HStack(spacing: 12) {
                Tile(label: "ชีพจรตอนเดิน", value: (dashboard.metric("walkingHeartRateAverage")?.value ?? 0).formatted(0), unit: "bpm")
                Tile(label: "ออกซิเจน", value: dashboard.metric("oxygenSaturation")?.value.map { ($0 * 100).formatted(0) } ?? "—", unit: "%")
            }
            .padding(.top, 12)
        }
    }

    private var fitness: some View {
        VStack(spacing: 0) {
            SectionTitle(text: "ความฟิต")
            Card {
                VStack(spacing: 0) {
                    let vo2 = dashboard.metric("vo2Max")
                    MetricRow(symbol: "chart.line.uptrend.xyaxis", title: "VO₂ max",
                              subtitle: vo2?.measuredAt.map { "วัดล่าสุด \($0.relativeThai)" } ?? "ยังไม่มีข้อมูล",
                              value: vo2?.value.map { $0.formatted(1) } ?? "—",
                              detail: vo2 == nil ? nil : "mL/kg·min",
                              tint: .orange)
                    if let workout = dashboard.workouts.first {
                        Divider()
                        MetricRow(symbol: "figure.run", title: "\(workout.activityTypeName) ล่าสุด",
                                  subtitle: "\(workout.startDate.relativeThai) · \((workout.durationSec / 60).formatted(0)) นาที"
                                      + (workout.avgHeartRate.map { " · \($0.formatted(0)) bpm" } ?? ""),
                                  value: ((workout.distanceM ?? 0) / 1000).formatted(2),
                                  detail: "km", showsChevron: false)
                    }
                }
            }
        }
    }
}
