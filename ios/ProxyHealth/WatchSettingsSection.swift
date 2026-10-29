import SwiftUI
import WorkoutKit

/// Settings for the watch hand-off: whether it happens, when a session is put on the watch, what
/// is on there now, and a way to clear it all.
///
/// The clear button is the reason the rest can be trusted. Scheduled workouts are the one thing
/// this app writes outside its own storage, so there has to be a way to put the watch back to
/// empty without touching the plan.
struct WatchSettingsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(Dashboard.self) private var dashboard

    @State private var exporting = SyncState.watchExport
    @State private var startMinute = SyncState.watchStartMinuteOfDay
    @State private var authorization: WorkoutScheduler.AuthorizationState?
    @State private var confirmingClear = false

    var body: some View {
        VStack(spacing: 0) {
            SectionTitle(text: "Apple Watch", hint: WorkoutExport.isSupported ? nil : "ไม่รองรับ")
            Card(vertical: 3) {
                VStack(spacing: 0) {
                    Toggle(isOn: Binding(get: { exporting }, set: { setExporting($0) })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("ส่งแผนเข้า Apple Watch").font(.system(size: 14.5, weight: .semibold))
                            Text("อัตโนมัติทุกครั้งที่ซิงก์ · \(WorkoutExport.sessionsAhead) ครั้งถัดไป")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 9)
                    .disabled(!WorkoutExport.isSupported)

                    Divider()
                    DatePicker(selection: Binding(get: { startDate }, set: { setStart($0) }),
                               displayedComponents: .hourAndMinute) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("เวลาเริ่มที่ตั้งให้").font(.system(size: 14.5, weight: .semibold))
                            Text("แผนไม่มีเวลาในตัว — ตั้งจากเวลาที่ซ้อมบ่อยที่สุด")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 9)

                    Divider()
                    MetricRow(
                        symbol: "applewatch",
                        title: "อยู่บนนาฬิกาตอนนี้",
                        subtitle: sweptLabel,
                        value: "\(dashboard.watchDates.count)",
                        detail: "งาน",
                        tint: Brand.blue
                    )
                }
            }

            if let note = dashboard.watchNote {
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)
                    .padding(.top, 8)
            }

            Card(vertical: 3) {
                Button(role: .destructive) { confirmingClear = true } label: {
                    MetricRow(
                        symbol: "trash",
                        title: "ล้างแผนทั้งหมดจากนาฬิกา",
                        subtitle: "ไม่กระทบแผนในปฏิทิน ส่งใหม่ได้ตลอด",
                        value: "",
                        tint: .red,
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)
                .disabled(dashboard.watchDates.isEmpty)
            }
            .padding(.top, 12)
        }
        .task {
            authorization = await WorkoutExport.authorization
            await dashboard.refreshWatchDates()
        }
        .confirmationDialog("ล้างแผนทั้งหมดจากนาฬิกา", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("ล้างทั้งหมด", role: .destructive) { Task { await dashboard.clearWatch() } }
            Button("ยกเลิก", role: .cancel) {}
        } message: {
            Text("แผนในปฏิทินยังอยู่ครบ กดส่งใหม่หรือรอรอบซิงก์ถัดไปก็กลับมา")
        }
    }

    private var startDate: Date {
        Calendar.current.date(bySettingHour: startMinute / 60, minute: startMinute % 60, second: 0, of: Date()) ?? Date()
    }

    private var sweptLabel: String {
        guard let at = SyncState.watchSweptAt else { return "ยังไม่เคยส่ง" }
        let dates = dashboard.watchDates.map { PlanFormat.dayLabel($0) }
        let when = "เก็บกวาดล่าสุด \(at.formatted(date: .omitted, time: .shortened))"
        return dates.isEmpty ? when : "\(when) · \(dates.joined(separator: ", "))"
    }

    private func setExporting(_ on: Bool) {
        exporting = on
        SyncState.watchExport = on
        Task {
            if on {
                // The permission prompt belongs here, when the switch is turned on, rather than
                // at launch where it would arrive with no explanation.
                if await WorkoutExport.authorization != .authorized {
                    authorization = await WorkoutExport.requestAuthorization()
                }
                await dashboard.syncWatch(force: true)
            } else {
                await dashboard.clearWatch()
            }
        }
    }

    private func setStart(_ date: Date) {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        startMinute = (parts.hour ?? 6) * 60 + (parts.minute ?? 30)
        SyncState.watchStartMinuteOfDay = startMinute
        // Already-scheduled sessions carry the old time, so they have to go back out.
        Task {
            await dashboard.clearWatch()
            await dashboard.syncWatch()
        }
    }
}
