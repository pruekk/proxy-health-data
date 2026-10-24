import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    var settings = SyncSettings.load()
    var isSyncing = false
    var isAuthorized = UserDefaults.standard.bool(forKey: "healthAuthorizationRequested")
    var lastReport: SyncReport?
    var lastSyncAt = SyncState.lastSyncAt
    var connection: String?
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
    }

    func testConnection() async {
        guard let client = APIClient(settings: settings) else {
            connection = SyncError.notConfigured.localizedDescription
            return
        }
        do {
            let profile = try await client.me()
            connection = "Connected as \(profile.uid)"
        } catch let error as APIError where error.status == 401 {
            connection = "Token rejected (\(settings.tokenHint)). Use the part of API_TOKENS before \":me\"."
        } catch {
            connection = "Failed: \(error.localizedDescription)"
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
        defer { isSyncing = false }
        do {
            let report = try await SyncEngine.shared.sync(trigger: trigger) { line in
                Task { @MainActor in self.appendLog(line) }
            }
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

    func resetSync() {
        SyncState.reset()
        lastSyncAt = nil
        lastReport = nil
        appendLog("Sync state reset; next sync re-uploads the backfill window")
    }
}
