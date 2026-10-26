import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    var settings = SyncSettings.load()
    var isSyncing = false
    /// Where the sync has got to, shown instead of a spinner that says nothing. A first sync
    /// takes minutes, so the phase, the count and the estimate all matter.
    var syncProgress: SyncProgress?
    var isAuthorized = UserDefaults.standard.bool(forKey: "healthAuthorizationRequested")
    var lastReport: SyncReport?
    var lastSyncAt = SyncState.lastSyncAt
    /// Result of the last `/v1/me` call, in words. `nil` until one has been made.
    var connection: String?
    var isConnected = false
    var errorMessage: String?
    var log: [String] = []

    func appendLog(_ line: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        log.insert("\(time)  \(line)", at: 0)
        if log.count > 50 { log.removeLast(log.count - 50) }
    }

    func requestAuthorization() async {
        do {
            try await SyncEngine.shared.requestAuthorization()
            isAuthorized = true
            UserDefaults.standard.set(true, forKey: "healthAuthorizationRequested")
            await SyncEngine.shared.startBackgroundDelivery()
            appendLog("HealthKit access requested")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveSettings(_ new: SyncSettings) {
        new.save()
        settings = SyncSettings.load()
        connection = nil
        isConnected = false
    }

    func testConnection() async {
        isConnected = false
        guard let client = APIClient(settings: settings) else {
            connection = SyncError.notConfigured.localizedDescription
            return
        }
        do {
            let profile = try await client.me()
            isConnected = true
            connection = "เชื่อมต่อแล้ว · \(profile.uid)"
        } catch let error as APIError where error.status == 401 {
            connection = "โทเคนไม่ถูกต้อง (\(settings.tokenHint)) — ใช้ส่วนหน้า \":me\" ของ API_TOKENS"
        } catch {
            connection = "เชื่อมต่อไม่ได้: \(error.localizedDescription)"
        }
    }

    var backgroundDeliveryEnabled = SyncState.backgroundDeliveryEnabled
    var syncOnlyWhileCharging: Bool = SyncState.syncOnlyWhileCharging {
        didSet { SyncState.syncOnlyWhileCharging = syncOnlyWhileCharging }
    }

    func setBackgroundDelivery(_ enabled: Bool) {
        backgroundDeliveryEnabled = enabled
        SyncState.backgroundDeliveryEnabled = enabled
        Task {
            if enabled {
                await SyncEngine.shared.startBackgroundDelivery()
                appendLog("เปิดซิงก์เบื้องหลัง")
            } else {
                await SyncEngine.shared.stopBackgroundDelivery()
                appendLog("ปิดซิงก์เบื้องหลัง")
            }
        }
    }

    func syncNow(trigger: SyncTrigger = .manual) async {
        guard !isSyncing else { return }
        isSyncing = true
        errorMessage = nil
        appendLog("Sync started")
        defer { isSyncing = false; syncProgress = nil }
        do {
            let report = try await SyncEngine.shared.sync(trigger: trigger) { progress in
                Task { @MainActor in
                    // One log line per phase: the per-metric updates are for the bar, not the log.
                    if self.syncProgress?.phase != progress.phase { self.appendLog(progress.phase.label) }
                    self.syncProgress = progress
                }
            }
            syncProgress = nil
            guard !report.skipped else {
                appendLog("ข้ามการซิงก์ — เพิ่งซิงก์ไปเมื่อครู่")
                return
            }
            lastReport = report
            lastSyncAt = report.finishedAt
            appendLog("ซิงก์เสร็จ: \(report.samples) samples, \(report.workouts) workouts, \(report.days) วัน")
            report.errors.forEach { appendLog("⚠︎ \($0)") }
        } catch {
            errorMessage = error.localizedDescription
            appendLog("Sync failed: \(error.localizedDescription)")
        }
    }

    /// Forgets every anchor and syncs straight away. It used to only clear the anchors and
    /// leave, so the screen sat there saying nothing while no work was happening at all.
    func resetSync() async {
        SyncState.reset()
        lastSyncAt = nil
        lastReport = nil
        appendLog("ล้าง anchor แล้ว — เริ่มดึงข้อมูลใหม่ทั้งหมด")
        await syncNow(trigger: .manual)
    }
}
