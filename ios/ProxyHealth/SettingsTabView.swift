import SwiftUI

/// Tab three: connection, data retention, and the things done once in a blue moon.
struct SettingsTabView: View {
    @Environment(AppModel.self) private var model
    @Environment(Dashboard.self) private var dashboard
    @State private var editingConnection = false
    @State private var confirmReset = false
    @State private var confirmDelete = false
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
        .task { await dashboard.load(settings: model.settings) }
        .sheet(isPresented: $editingConnection) { ConnectionSheet(settings: model.settings) }
        .alert("ซิงก์ใหม่ทั้งหมด?", isPresented: $confirmReset) {
            Button("ยกเลิก", role: .cancel) {}
            Button("ซิงก์ใหม่", role: .destructive) { model.resetSync() }
        } message: {
            Text("ลืม anchor ทั้งหมดแล้วดึงข้อมูลใหม่ตามนโยบาย backfill ข้อมูลเดิมบนเซิร์ฟเวอร์ไม่หาย")
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
                MetricRow(symbol: model.connection?.hasPrefix("Connected") == true ? "checkmark.circle.fill" : "exclamationmark.circle",
                          title: model.connection ?? "ยังไม่ได้ตรวจสอบ",
                          subtitle: URL(string: model.settings.serverURL)?.host(),
                          value: "", tint: model.connection?.hasPrefix("Connected") == true ? .green : .orange)
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

    private var retention: some View {
        VStack(spacing: 0) {
            SectionTitle(text: "ข้อมูล")
            Card {
                Text("เก็บข้อมูลย้อนหลัง").font(.system(size: 10.5, weight: .bold)).kerning(0.9).foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { dashboard.retentionYears },
                    set: { years in Task { await setRetention(years) } }
                )) {
                    Text("1 ปี").tag(1)
                    Text("2 ปี").tag(2)
                    Text("5 ปี").tag(5)
                }
                .pickerStyle(.segmented)
                .padding(.top, 10)
                Text("ข้อมูลที่เก่ากว่านี้จะถูกลบออกอัตโนมัติ ส่วนค่าที่บันทึกถี่มาก (ชีพจร ความเร็ว) เก็บ raw ไว้ 7 วัน ยกเว้นช่วงที่ออกกำลังกาย — สรุปรายชั่วโมงและรายวันยังอยู่ครบตามช่วงที่เลือก")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary).padding(.top, 10)
            }
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
                                  subtitle: "ลืม anchor แล้วดึงใหม่ตาม backfill", value: "", showsChevron: true)
                    }
                    .buttonStyle(.plain)
                    Divider()
                    Button { Task { await requestPermissions() } } label: {
                        MetricRow(symbol: "heart.text.square", title: "ขอสิทธิ์ Health ที่ยังขาด",
                                  subtitle: "สำหรับ metric ที่เพิ่งเพิ่มใน catalog", value: "", showsChevron: true)
                    }
                    .buttonStyle(.plain)
                    Divider()
                    Button { Task { await revokeConnectors() } } label: {
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

    private func setRetention(_ years: Int) async {
        guard let client = APIClient(settings: model.settings) else { return }
        busy = "กำลังบันทึก…"
        defer { busy = nil }
        do {
            try await client.put("v1/settings", body: ["retentionYears": years])
            await dashboard.load(settings: model.settings, force: true)
            model.appendLog("เปลี่ยนการเก็บข้อมูลเป็น \(years) ปี")
        } catch {
            busy = error.localizedDescription
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
