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
                    dashboard.refreshLocalSyncs()
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

    private var latest: SyncLogDoc? { dashboard.lastSync }

    private var timeline: some View {
        VStack(spacing: 0) {
            SectionTitle(text: "ไทม์ไลน์")
            Card {
                if dashboard.syncHistory.isEmpty {
                    Text("ยังไม่มีประวัติ — ซิงก์ครั้งแรกจะเริ่มบันทึก")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(dashboard.syncHistory.prefix(12)) { entry in
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
                            if entry.id != dashboard.syncHistory.prefix(12).last?.id { Divider() }
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
            SectionTitle(text: "ความครอบคลุม")
            Text("แต่ละกลุ่มเก็บไม่เท่ากันตามที่ตั้งไว้ในแท็บตั้งค่า — ข้อมูลดิบที่บันทึกถี่มากเก็บสั้นที่สุด ยกเว้นช่วงที่ออกกำลังกายซึ่งเก็บเท่ากลุ่มการซ้อม")
                .font(.system(size: 12)).lineSpacing(2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2).padding(.bottom, 10)
            Card(vertical: 3) {
                VStack(spacing: 0) {
                    let rows = coverageRows
                    ForEach(rows, id: \.type) { row in
                        MetricRow(symbol: row.symbol, title: row.name, subtitle: row.storage,
                                  value: row.latest, detail: row.latestDetail, tint: .secondary)
                        if row.type != rows.last?.type { Divider() }
                    }
                    if rows.isEmpty {
                        Text("ยังไม่มีข้อมูลซิงก์").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private struct CoverageRow {
        let type: String
        let name: String
        let symbol: String
        let storage: String
        let latest: String
        let latestDetail: String?
    }

    /// Reads as "what it is, how it is kept, when it last arrived" rather than raw metric keys.
    private var coverageRows: [CoverageRow] {
        // Which rows, their names and the window each one is on all come from the server, so a
        // retention change shows up here without a rebuild.
        return AppConfig.display.coverage.compactMap { (item: RemoteCatalog.Row) -> CoverageRow? in
            guard let metric = dashboard.metric(item.key) else { return nil }
            let kept = dashboard.windowLabel(for: item.key)
            let count = metric.count.map { "\($0) รายการ" } ?? "—"
            return CoverageRow(
                type: item.key,
                name: item.name,
                symbol: item.symbol ?? "circle.dashed",
                storage: "ดิบ · \(kept) · \(count)",
                latest: metric.measuredAt.map { $0.relativeThai } ?? "—",
                latestDetail: metric.measuredAt.map { $0.formatted(date: .omitted, time: .shortened) }
            )
        }
    }

    private func coverageRange(_ metric: MetricSummary) -> String {
        guard let first = metric.firstAt else { return "ยังไม่ทราบช่วงข้อมูล" }
        let last = metric.measuredAt ?? Date()
        let days = Calendar.current.dateComponents([.day], from: first, to: last).day ?? 0
        return "\(first.formatted(.dateTime.day().month(.abbreviated))) – ล่าสุด · \(days) วัน"
    }

}
