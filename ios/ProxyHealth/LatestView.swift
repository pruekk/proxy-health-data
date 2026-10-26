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
                if let readiness = dashboard.readiness {
                    ReadinessCard(readiness: readiness)
                } else if dashboard.isLoading || dashboard.loadedAt == nil {
                    // A placeholder rather than nothing: the card appearing late looked like it
                    // had been removed.
                    ReadinessCard(readiness: .placeholder, placeholder: true).redacted(reason: .placeholder)
                }
                if let battery = dashboard.battery {
                    BatteryCard(battery: battery)
                } else if dashboard.isLoading || dashboard.loadedAt == nil {
                    BatteryCard(battery: .placeholder, placeholder: true).redacted(reason: .placeholder)
                }
                rings
                todayTiles
                heart
                fitness
                workouts
                body_
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 110)
        }
        .background(Brand.ground)
        .refreshable {
            await model.syncNow(trigger: .manual)
            dashboard.refreshLocalSyncs()
            await dashboard.load(settings: model.settings, force: true)
        }
        .task { await dashboard.load(settings: model.settings) }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("วันนี้").font(.system(size: 24, weight: .bold))
                Text(model.syncProgress?.line ?? syncLine)
                    .font(.system(size: 13))
                    .foregroundStyle(model.syncProgress == nil ? .secondary : Brand.blue)
                    .lineLimit(1)
                    .animation(.default, value: model.syncProgress?.line)
                if let progress = model.syncProgress {
                    ProgressView(value: progress.fraction)
                        .tint(Brand.blue)
                        .frame(maxWidth: 220)
                        .padding(.top, 4)
                        .animation(.default, value: progress.fraction)
                }
            }
            Spacer()
            Button {
                Task {
                    await model.syncNow(trigger: .manual)
                    dashboard.refreshLocalSyncs()
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
        guard let at = model.lastSyncAt ?? dashboard.lastSync?.startedAt else { return "ยังไม่เคยซิงก์" }
        return RelativeThai.syncedPhrase(at)
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

    /// Rows, names and units come from the server catalog, so a new body metric appears with a
    /// deploy instead of a rebuild.
    private var body_: some View {
        VStack(spacing: 0) {
            SectionTitle(text: "ร่างกาย", hint: bodyMeasuredHint)
            Card(vertical: 3) {
                VStack(spacing: 0) {
                    let rows = AppConfig.display.body
                    ForEach(rows) { item in
                        row(item)
                        if item.id != rows.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private var bodyMeasuredHint: String? {
        guard let at = dashboard.metric("bodyMass")?.measuredAt else { return nil }
        return "วัดล่าสุด \(at.relativeThai)"
    }

    private func row(_ item: RemoteCatalog.Row) -> some View {
        let type = item.key
        let scale = item.scale ?? 1
        let decimals = item.decimals ?? 1
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
        return MetricRow(symbol: item.symbol ?? "circle.dashed", title: item.name, subtitle: subtitle,
                         value: item.unit.map { "\(value) \($0)" } ?? value, detail: detail, detailStyle: style)
    }

    /// Two tiles per line, in catalog order.
    private var heart: some View {
        let tiles = AppConfig.display.vitals
        return VStack(spacing: 0) {
            SectionTitle(text: "หัวใจและการหายใจ")
            ForEach(Array(stride(from: 0, to: tiles.count, by: 2)), id: \.self) { index in
                HStack(spacing: 12) {
                    tile(tiles[index])
                    if index + 1 < tiles.count { tile(tiles[index + 1]) } else { Color.clear.frame(height: 0) }
                }
                .padding(.top, index == 0 ? 0 : 12)
            }
        }
    }

    private func tile(_ item: RemoteCatalog.Row) -> some View {
        let scale = item.scale ?? 1
        let decimals = item.decimals ?? 1
        let value = dashboard.metric(item.key)?.value.map { ($0 * scale).formatted(decimals) } ?? "—"
        let meta = item.averageDays.flatMap { days in
            dashboard.average(item.key, lastDays: days).map { "เฉลี่ย \(days) วัน \(($0 * scale).formatted(decimals))" }
        }
        return Tile(label: item.name, value: value, unit: item.unit, meta: meta)
    }

    /// The most recent sessions. More than a couple because several runs can land on the same
    /// day, and one row would then hide the rest; the count comes from the catalog.
    private var workouts: some View {
        Group {
            if !dashboard.workouts.isEmpty {
                VStack(spacing: 0) {
                    SectionTitle(text: "ออกกำลังกายล่าสุด")
                    Card(vertical: 3) {
                        VStack(spacing: 0) {
                            let recent = Array(dashboard.workouts.prefix(AppConfig.recentWorkouts))
                            ForEach(recent) { workout in
                                MetricRow(
                                    symbol: "figure.run",
                                    title: "\(workout.activityTypeName) · \(((workout.distanceM ?? 0) / 1000).formatted(2)) km",
                                    subtitle: workoutSubtitle(workout),
                                    value: (workout.durationSec / 60).formatted(0),
                                    detail: "นาที"
                                )
                                if workout.id != recent.last?.id { Divider() }
                            }
                        }
                    }
                }
            }
        }
    }

    private func workoutSubtitle(_ workout: WorkoutDoc) -> String {
        var parts = [workout.startDate.relativeThai]
        if let hr = workout.avgHeartRate { parts.append("\(hr.formatted(0)) bpm") }
        if let temp = workout.weatherTempC { parts.append("\(temp.formatted(1))°C") }
        return parts.joined(separator: " · ")
    }

    private var fitness: some View {
        VStack(spacing: 0) {
            SectionTitle(text: "ความฟิต")
            Card(vertical: 3) {
                VStack(spacing: 0) {
                    let vo2 = dashboard.metric("vo2Max")
                    MetricRow(symbol: "chart.line.uptrend.xyaxis", title: "VO₂ max",
                              subtitle: vo2?.measuredAt.map { "วัดล่าสุด \($0.relativeThai)" } ?? "ยังไม่มีข้อมูล",
                              value: vo2?.value.map { $0.formatted(1) } ?? "—",
                              detail: vo2 == nil ? nil : "mL/kg·min",
                              tint: .orange)
                }
            }
        }
    }
}
