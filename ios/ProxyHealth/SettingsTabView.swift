import SwiftUI

/// Tab three: connection, data retention, and the things done once in a blue moon.
struct SettingsTabView: View {
    @Environment(AppModel.self) private var model
    @Environment(Dashboard.self) private var dashboard
    @State private var editingConnection = false
    @State private var confirmReset = false
    @State private var confirmDelete = false
    @State private var confirmRevoke = false
    @State private var editingGroup: RetentionGroup?
    /// The change waiting on confirmation, because shrinking a window deletes for good.
    @State private var pendingChange: (group: RetentionGroup, value: Int)?
    @State private var retentionProgress: RetentionProgress?
    @State private var busy: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                header
                connection
                retention
                automation
                rarely
                about
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 110)
        }
        .background(Brand.ground)
        .task {
            await dashboard.load(settings: model.settings)
            // Checked on open rather than only behind the token sheet: the row used to read
            // "ยังไม่ได้ตรวจสอบ" on every cold start even while syncing worked fine.
            if model.connection == nil { await model.testConnection() }
        }
        .sheet(isPresented: $editingConnection) { ConnectionSheet(settings: model.settings) }
        .alert("ซิงก์ใหม่ทั้งหมด?", isPresented: $confirmReset) {
            Button("ยกเลิก", role: .cancel) {}
            Button("ซิงก์ใหม่", role: .destructive) { Task { await model.resetSync() } }
        } message: {
            Text("ลืม anchor ทั้งหมดแล้วเริ่มดึงข้อมูลใหม่ทันที ใช้เวลาหลายนาทีเพราะคำนวณย้อนหลังทั้งช่วง เปิดแอปค้างไว้จนกว่าแถบความคืบหน้าจะเต็ม — ข้อมูลเดิมบนเซิร์ฟเวอร์ไม่หาย")
        }
        .alert("ตัดการเชื่อมต่อ connector ทั้งหมด?", isPresented: $confirmRevoke) {
            Button("ยกเลิก", role: .cancel) {}
            Button("ตัดการเชื่อมต่อ", role: .destructive) { Task { await revokeConnectors() } }
        } message: {
            Text("Claude จะหลุดทันทีและต้องเข้าสู่ระบบใหม่ โทเคนของแอปนี้ยังใช้ได้ตามเดิม")
        }
        // Shrinking a window deletes for good, so it asks first and then re-stamps what is
        // already stored — otherwise the setting would only affect future writes.
        .alert(pendingChange.map { "เก็บ\($0.group.name) \($0.group.label($0.value))?" } ?? "", isPresented: .init(
            get: { pendingChange != nil },
            set: { if !$0 { pendingChange = nil } }
        )) {
            Button("ยกเลิก", role: .cancel) { pendingChange = nil }
            Button(shrinking ? "ลดลง" : "เปลี่ยน", role: shrinking ? .destructive : nil) {
                if let change = pendingChange { Task { await applyRetention(change.group, change.value) } }
            }
        } message: {
            Text(shrinking
                 ? "ข้อมูลในกลุ่มนี้ที่เก่ากว่านั้นจะถูกลบภายใน 24 ชั่วโมง\n\nต้นฉบับยังอยู่ที่ Apple Health — กดซิงก์ใหม่ทั้งหมดเพื่อดึงกลับได้ เท่าที่ Health ยังเก็บไว้"
                 : "ข้อมูลเดิมในกลุ่มนี้จะถูกยืดอายุตามไปด้วย ไม่ใช่เฉพาะข้อมูลใหม่")
        }
        .sheet(item: $editingGroup) { group in
            RetentionGroupSheet(
                group: group,
                current: dashboard.retention[group.id] ?? group.default,
                metrics: dashboard.storedMetrics(in: group.id),
                onPick: { value in
                    editingGroup = nil
                    if value != (dashboard.retention[group.id] ?? group.default) {
                        pendingChange = (group, value)
                    }
                }
            )
        }
        .alert("ลบข้อมูลทั้งหมด?", isPresented: $confirmDelete) {
            Button("ยกเลิก", role: .cancel) {}
            Button("ลบทั้งหมด", role: .destructive) { Task { await deleteAll() } }
        } message: {
            Text("ลบทุก sample, workout, สรุปรายวัน/รายชั่วโมง และประวัติการซิงก์ของผู้ใช้นี้ กู้คืนไม่ได้")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("ตั้งค่า").font(.system(size: 24, weight: .bold))
            Text("เชื่อมต่อ · ข้อมูล · การล้างข้อมูล").font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    private var connection: some View {
        Card {
            Text("การเชื่อมต่อ").font(.system(size: 10.5, weight: .bold)).kerning(0.9).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                MetricRow(symbol: model.isConnected ? "checkmark.circle.fill" : "exclamationmark.circle",
                          title: model.connection ?? "กำลังตรวจสอบ…",
                          subtitle: URL(string: model.settings.serverURL)?.host(),
                          value: "", tint: model.isConnected ? .green : .orange)
                Divider()
                Button { editingConnection = true } label: {
                    MetricRow(symbol: "key", title: "API token", subtitle: model.settings.tokenHint,
                              value: "เปลี่ยน", showsChevron: true)
                }
                .buttonStyle(.plain)
                Divider()
                MetricRow(symbol: "app.connected.to.app.below.fill", title: "Connector ที่เชื่อมอยู่",
                          subtitle: dashboard.connectors.first?.clientName ?? "ยังไม่มี",
                          value: "\(dashboard.connectors.count)", detail: "เครื่อง")
            }
            .padding(.top, 6)
        }
    }

    /// Five rows rather than one window for everything: the groups behave differently enough
    /// that a single number forces a choice between losing the multi-year lines and paying for
    /// the high-frequency noise. Tapping a row opens the window picker for that group.
    private var retention: some View {
        VStack(spacing: 0) {
            SectionTitle(text: "ข้อมูล", hint: dashboard.totalDocuments.map { "\($0.formatted(0)) เอกสาร" })
            Card(vertical: 3) {
                VStack(spacing: 0) {
                    let groups = dashboard.retentionGroups
                    ForEach(groups) { group in
                        Button { editingGroup = group } label: { groupRow(group) }
                            .buttonStyle(.plain)
                        if group.id != groups.last?.id { Divider() }
                    }
                    if groups.isEmpty {
                        Text("กำลังโหลดการตั้งค่า…").font(.system(size: 13)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                    }
                }
                Text("ที่นี่เป็นสำเนาเพื่อให้ AI อ่านได้ ต้นฉบับอยู่ที่ Apple Health เสมอ — ลบแล้วกดซิงก์ใหม่ก็ได้คืน")
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    .padding(.top, 10).padding(.horizontal, 2)

                if let progress = retentionProgress {
                    VStack(alignment: .leading, spacing: 7) {
                        ProgressView(value: progress.fraction).tint(Brand.blue)
                        Text(progress.label).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    .padding(.top, 12)
                }
            }
        }
    }

    private func groupRow(_ group: RetentionGroup) -> some View {
        let count = dashboard.documentCount(in: group.id)
        let window = dashboard.retention[group.id] ?? group.default
        return HStack(spacing: 10) {
            Circle().fill(color(for: group.id)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name).font(.system(size: 13.5, weight: .medium))
                Text(count > 0 ? "\(group.summary) · \(count.formatted(0))" : group.summary)
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(group.label(window)).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    private func color(for group: String) -> Color {
        switch group {
        case "raw": .red
        case "recovery": Brand.blue
        case "training": .orange
        case "body": Brand.exercise
        default: .purple
        }
    }

    private var automation: some View {
        Card(vertical: 3) {
            VStack(spacing: 0) {
                Toggle(isOn: Binding(
                    get: { model.backgroundDeliveryEnabled },
                    set: { model.setBackgroundDelivery($0) }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("ซิงก์อัตโนมัติเบื้องหลัง").font(.system(size: 14.5, weight: .semibold))
                        Text("เมื่อ Apple Health มีข้อมูลใหม่").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 9)
                Divider()
                Toggle(isOn: Binding(
                    get: { model.syncOnlyWhileCharging },
                    set: { model.syncOnlyWhileCharging = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("ซิงก์เบื้องหลังเฉพาะตอนชาร์จ").font(.system(size: 14.5, weight: .semibold))
                        Text("ลดการใช้แบตเตอรี่").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 9)
                .disabled(!model.backgroundDeliveryEnabled)
            }
        }
    }

    private var rarely: some View {
        VStack(spacing: 0) {
            SectionTitle(text: "นาน ๆ ทำที")
            Card(vertical: 3) {
                VStack(spacing: 0) {
                    Button { confirmReset = true } label: {
                        MetricRow(symbol: "arrow.clockwise.circle", title: "ซิงก์ใหม่ทั้งหมด",
                                  subtitle: model.isSyncing ? "กำลังทำงาน…" : "ลืม anchor แล้วดึงใหม่ตาม backfill",
                                  value: "", showsChevron: !model.isSyncing)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isSyncing)
                    Divider()
                    Button { Task { await requestPermissions() } } label: {
                        MetricRow(symbol: "heart.text.square", title: "ขอสิทธิ์ Health ที่ยังขาด",
                                  subtitle: "สำหรับ metric ที่เพิ่งเพิ่มใน catalog", value: "", showsChevron: true)
                    }
                    .buttonStyle(.plain)
                    Divider()
                    Button { confirmRevoke = true } label: {
                        MetricRow(symbol: "xmark.shield", title: "ตัดการเชื่อมต่อ connector ทั้งหมด",
                                  subtitle: "โทเคนของแอปนี้ยังใช้ได้ตามเดิม", value: "", showsChevron: true)
                    }
                    .buttonStyle(.plain)
                    Divider()
                    Button { confirmDelete = true } label: {
                        MetricRow(symbol: "trash", title: "ลบข้อมูลทั้งหมดบนเซิร์ฟเวอร์",
                                  subtitle: "กู้คืนไม่ได้", value: "", tint: .red, showsChevron: true)
                    }
                    .buttonStyle(.plain)
                }
            }
            if let progress = model.syncProgress {
                VStack(alignment: .leading, spacing: 7) {
                    ProgressView(value: progress.fraction).tint(Brand.blue)
                    HStack(alignment: .firstTextBaseline) {
                        Text(progress.line).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text("\(progress.percent)%")
                            .font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 10).padding(.horizontal, 2)
                .animation(.default, value: progress.fraction)
            } else if model.isSyncing {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("กำลังเริ่ม…").font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8).padding(.horizontal, 2)
            }
            if let busy {
                Text(busy).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8).padding(.horizontal, 2)
            }
        }
    }

    private var about: some View {
        VStack(spacing: 0) {
            SectionTitle(text: "เกี่ยวกับ")
            Card(vertical: 3) {
                VStack(spacing: 0) {
                    MetricRow(symbol: "list.bullet.rectangle", title: "Catalog",
                              subtitle: "ดึงจากเซิร์ฟเวอร์ · \(CatalogStore.cached?.quantities.count ?? HealthCatalog.quantities.count) metric",
                              value: String((CatalogStore.cached?.version ?? "built-in").prefix(8)), tint: .secondary)
                    Divider()
                    MetricRow(symbol: "app.badge", title: "เวอร์ชันแอป", subtitle: nil,
                              value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—", tint: .secondary)
                }
            }
        }
    }

    // MARK: Actions

    private var shrinking: Bool {
        guard let change = pendingChange else { return false }
        return change.value < (dashboard.retention[change.group.id] ?? change.group.default)
    }

    /// Saves the new window and re-stamps what is already stored. The work is per scope, so the
    /// progress is a real count rather than a spinner that cannot say how far along it is.
    private func applyRetention(_ group: RetentionGroup, _ value: Int) async {
        guard let client = APIClient(settings: model.settings) else { return }
        pendingChange = nil
        do {
            try await client.put("v1/settings", body: ["retention": [group.id: value]])
            model.appendLog("เก็บ\(group.name) \(group.label(value))")

            // Only the scopes this group owns, plus the shared aggregates when the group they
            // follow changed. Re-stamping every metric for a change to one of them was most of
            // the wait and none of the work.
            let keys = AppConfig.metricKeys(in: group.id)
            let scopes = dashboard.metrics.keys.filter { keys.contains($0) }.sorted()
                + (group.id == "training" ? ["daily", "hourly", "workouts"] : [])
            var stamped = 0
            for (index, scope) in scopes.enumerated() {
                retentionProgress = RetentionProgress(done: index, total: scopes.count, stamped: stamped, scope: scope)
                var cursor: String?
                repeat {
                    let query = cursor.map { "&after=\($0)" } ?? ""
                    let result: RetentionResult = try await client.postDecoding(
                        "v1/retention/apply?scope=\(scope)&dryRun=false\(query)"
                    )
                    stamped += result.stamped
                    cursor = result.done ? nil : result.after
                } while cursor != nil
            }
            retentionProgress = RetentionProgress(done: scopes.count, total: scopes.count, stamped: stamped, scope: nil)
            await dashboard.load(settings: model.settings, force: true)
            try? await Task.sleep(for: .seconds(2))
            retentionProgress = nil
        } catch {
            busy = error.localizedDescription
            retentionProgress = nil
        }
    }

    private func requestPermissions() async {
        await SyncEngine.shared.requestNewReadTypes(force: true)
        model.appendLog("ขอสิทธิ์ Health ที่ยังขาดแล้ว")
    }

    private func revokeConnectors() async {
        guard let client = APIClient(settings: model.settings) else { return }
        busy = "กำลังตัดการเชื่อมต่อ…"
        defer { busy = nil }
        do {
            let _: Data = try await client.getRaw("v1/me") // keeps the call shape simple below
            try await client.post("v1/revoke-connectors")
            await dashboard.load(settings: model.settings, force: true)
        } catch {
            busy = error.localizedDescription
        }
    }

    private func deleteAll() async {
        guard let client = APIClient(settings: model.settings) else { return }
        busy = "กำลังลบ…"
        defer { busy = nil }
        do {
            try await client.delete("v1/data")
            await dashboard.load(settings: model.settings, force: true)
            model.appendLog("ลบข้อมูลทั้งหมดบนเซิร์ฟเวอร์แล้ว")
        } catch {
            busy = error.localizedDescription
        }
    }
}
