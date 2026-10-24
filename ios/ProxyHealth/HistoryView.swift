import SwiftUI

/// Tab two: what the app has been doing and how far back the data goes.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                header
                status
                timeline
                coverage
                recentWorkouts
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 110)
        }
        .background(Brand.ground)
        .refreshable { await dashboard.load(settings: model.settings, force: true) }
        .task { await dashboard.load(settings: model.settings) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("ประวัติ").font(.system(size: 24, weight: .bold))
            Text("การซิงก์และความครอบคลุมข้อมูล").font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    private var status: some View {
        Card {
            Text("สถานะล่าสุด").font(.system(size: 10.5, weight: .bold)).kerning(0.9).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(latest?.failed == true ? "มีข้อผิดพลาด" : (latest == nil ? "ยังไม่เคยซิงก์" : "สำเร็จ"))
                    .font(.system(size: 26, weight: .bold))
                if let at = latest?.startedAt {
                    Text(at.relativeThai).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)

            if let latest {
                HStack {
                    Text("\(latest.samples ?? 0) samples")
                    Spacer()
                    Text("\(latest.workouts ?? 0) workouts")
                    Spacer()
                    Text("\(latest.days ?? 0) วัน")
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.top, 10)
            }

            Button {
                Task {
                    await model.syncNow(trigger: .manual)
                    await dashboard.load(settings: model.settings, force: true)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                    Text(model.isSyncing ? "กำลังซิงก์…" : "ซิงก์เดี๋ยวนี้").fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(Brand.gradient, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(model.isSyncing)
            .padding(.top, 14)
        }
    }

    private var latest: SyncLogDoc? { dashboard.syncs.first }

    private var timeline: some View {
        VStack(spacing: 0) {
            SectionTitle(text: "ไทม์ไลน์")
            Card {
                if dashboard.syncs.isEmpty {
                    Text("ยังไม่มีประวัติ — ซิงก์ครั้งแรกจะเริ่มบันทึก")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(dashboard.syncs.prefix(12)) { entry in
                            HStack(alignment: .top, spacing: 11) {
                                Circle()
                                    .fill(entry.failed ? Color.orange : Brand.blue)
                                    .frame(width: 9, height: 9)
                                    .padding(.top, 5)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 7) {
                                        Text(triggerName(entry.trigger)).font(.system(size: 14, weight: .semibold))
                                        Text(entry.startedAt.formatted(date: .omitted, time: .shortened))
                                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                                    }
                                    Text(summary(entry)).font(.system(size: 12.5)).foregroundStyle(.secondary)
                                    if let errors = entry.errors, !errors.isEmpty {
                                        Text(errors.prefix(2).joined(separator: " · "))
                                            .font(.system(size: 12)).foregroundStyle(.orange)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 9)
                            if entry.id != dashboard.syncs.prefix(12).last?.id { Divider() }
                        }
                    }
                }
            }
        }
    }

    private func triggerName(_ trigger: String?) -> String {
        switch trigger {
        case "background": "ซิงก์อัตโนมัติ"
        case "foreground": "เปิดแอป"
        default: "ซิงก์เอง"
        }
    }

    private func summary(_ entry: SyncLogDoc) -> String {
        var parts: [String] = []
        if let n = entry.samples, n > 0 { parts.append("\(n) samples") }
        if let n = entry.workouts, n > 0 { parts.append("\(n) workouts") }
        if let n = entry.days, n > 0 { parts.append("\(n) วัน") }
        if let ms = entry.durationMs { parts.append("\((ms / 1000).formatted(1)) วิ") }
        return parts.isEmpty ? "ไม่มีข้อมูลใหม่" : parts.joined(separator: " · ")
    }

    private var coverage: some View {
        VStack(spacing: 0) {
            SectionTitle(text: "ความครอบคลุม", hint: "เก็บ \(dashboard.retentionYears) ปี")
            Card {
                VStack(spacing: 0) {
                    let interesting = ["heartRate", "bodyMass", "vo2Max", "sleepAnalysis"]
                    if interesting.allSatisfy({ dashboard.metric($0) == nil }) {
                        Text("ยังไม่มีข้อมูลซิงก์").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    ForEach(interesting, id: \.self) { type in
                        if let metric = dashboard.metric(type) {
                            MetricRow(symbol: "chart.bar.doc.horizontal", title: type,
                                      subtitle: coverageRange(metric),
                                      value: metric.sampleCount.map { "\($0)" } ?? "—",
                                      detail: "samples", tint: .secondary)
                            if type != interesting.last { Divider() }
                        }
                    }
                }
            }
        }
    }

    private func coverageRange(_ metric: MetricSummary) -> String {
        guard let first = metric.firstAt else { return "ยังไม่ทราบช่วงข้อมูล" }
        let last = metric.measuredAt ?? Date()
        let days = Calendar.current.dateComponents([.day], from: first, to: last).day ?? 0
        return "\(first.formatted(.dateTime.day().month(.abbreviated))) – ล่าสุด · \(days) วัน"
    }

    private var recentWorkouts: some View {
        VStack(spacing: 0) {
            SectionTitle(text: "ออกกำลังกายล่าสุด")
            Card {
                VStack(spacing: 0) {
                    ForEach(dashboard.workouts.prefix(5)) { workout in
                        MetricRow(
                            symbol: "figure.run",
                            title: "\(workout.activityTypeName) · \(((workout.distanceM ?? 0) / 1000).formatted(2)) km",
                            subtitle: subtitle(workout),
                            value: (workout.durationSec / 60).formatted(0),
                            detail: "นาที"
                        )
                        if workout.id != dashboard.workouts.prefix(5).last?.id { Divider() }
                    }
                    if dashboard.workouts.isEmpty {
                        Text("ยังไม่มีข้อมูลการออกกำลังกาย").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func subtitle(_ workout: WorkoutDoc) -> String {
        var parts = [workout.startDate.relativeThai]
        if let hr = workout.avgHeartRate { parts.append("\(hr.formatted(0)) bpm") }
        if let temp = workout.weatherTempC { parts.append("\(temp.formatted(1))°C") }
        return parts.joined(separator: " · ")
    }
}
