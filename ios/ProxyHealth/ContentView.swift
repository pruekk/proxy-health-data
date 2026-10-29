import SwiftUI

/// Four tabs under a floating bar: where things stand, what the plan says, what the app has
/// been doing, and the settings you touch once in a while.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var dashboard = Dashboard()
    @State private var tab: AppTab = .latest
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch tab {
                case .latest: LatestView()
                case .calendar: CalendarView()
                case .history: HistoryView()
                case .settings: SettingsTabView()
                }
            }
            .environment(dashboard)

            FloatingTabBar(selection: $tab).padding(.bottom, 6)
        }
        .background(Brand.ground)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, model.isAuthorized, model.settings.isConfigured else { return }
            Task {
                await model.syncNow(trigger: .foreground)
                // Nothing used to refresh the screen after a sync, so the numbers stayed stale
                // until the next pull-to-refresh.
                dashboard.refreshLocalSyncs()
                await dashboard.load(settings: model.settings, force: true)
            }
        }
        .overlay(alignment: .top) {
            if let error = model.errorMessage {
                Text(error)
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.red.opacity(0.9), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.top, 4)
                    .onTapGesture { model.errorMessage = nil }
            }
        }
    }
}

/// Server URL, token and backfill windows — the things set once when connecting.
struct ConnectionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var settings: SyncSettings

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(SyncSettings.defaultServerURL, text: $settings.serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("API token", text: $settings.token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("เซิร์ฟเวอร์")
                } footer: {
                    Text("วางค่าจาก API_TOKENS ได้ทั้งแบบเต็ม (token:me) หรือเฉพาะโทเคน")
                }

                Section("ดึงย้อนหลังครั้งแรก") {
                    Stepper("ตัวอย่างดิบ: \(settings.sampleBackfillDays) วัน",
                            value: $settings.sampleBackfillDays, in: 1...365)
                    Stepper("สรุปรายวันและ workout: \(settings.dailyBackfillDays) วัน",
                            value: $settings.dailyBackfillDays, in: 7...1825, step: 30)
                }

                Section {
                    Button("ทดสอบการเชื่อมต่อ") { Task { await model.testConnection() } }
                    if let connection = model.connection {
                        Text(connection).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("การเชื่อมต่อ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("ยกเลิก") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("บันทึก") {
                        model.saveSettings(settings)
                        Task { await model.testConnection() }
                        dismiss()
                    }
                }
            }
        }
    }
}
