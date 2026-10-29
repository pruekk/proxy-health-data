import Foundation
import HealthKit
import Security

/// Connection settings. The URL lives in UserDefaults, the bearer token in the Keychain.
struct SyncSettings: Sendable {
    var serverURL: String
    var token: String
    /// How far back raw samples (heart rate, sleep, …) are fetched on the first sync.
    var sampleBackfillDays: Int
    /// How far back daily aggregates and activity rings are fetched on the first sync.
    var dailyBackfillDays: Int

    var isConfigured: Bool { URL(string: serverURL)?.host != nil && !token.isEmpty }

    private enum Keys {
        static let serverURL = "serverURL"
        static let sampleBackfillDays = "sampleBackfillDays"
        static let dailyBackfillDays = "dailyBackfillDays"
        static let dailyBackfillMigrated = "dailyBackfillMigrated.v2"
        static let token = "apiToken"
    }

    /// Production API on Cloud Run (Firebase project proxy-health-data).
    static let defaultServerURL = "https://proxy-health-api-569148641622.asia-southeast1.run.app"

    static let defaultDailyBackfillDays = 730

    static func load() -> SyncSettings {
        let defaults = UserDefaults.standard
        // Earlier builds defaulted to the local dev server; move those installs to production.
        let stored = defaults.string(forKey: Keys.serverURL)
        // Installs from before the window was widened kept the old 90-day default, which is too
        // shallow for year-over-year trends. Bump those once; a value the user picked is left alone.
        if !defaults.bool(forKey: Keys.dailyBackfillMigrated) {
            defaults.set(true, forKey: Keys.dailyBackfillMigrated)
            if (defaults.object(forKey: Keys.dailyBackfillDays) as? Int) == 90 {
                defaults.set(defaultDailyBackfillDays, forKey: Keys.dailyBackfillDays)
                SyncState.dailyBackfillDone = false
            }
        }
        var token = Keychain.read(Keys.token) ?? ""
        #if DEBUG
        // Lets the simulator talk to the real API without typing a token in:
        //   SIMCTL_CHILD_PROXY_HEALTH_TOKEN=… xcrun simctl launch booted <bundle id>
        if let injected = ProcessInfo.processInfo.environment["PROXY_HEALTH_TOKEN"], !injected.isEmpty {
            token = injected
        }
        #endif
        return SyncSettings(
            serverURL: stored == nil || stored == "http://localhost:3000" ? defaultServerURL : stored!,
            token: token,
            sampleBackfillDays: defaults.object(forKey: Keys.sampleBackfillDays) as? Int ?? 7,
            dailyBackfillDays: defaults.object(forKey: Keys.dailyBackfillDays) as? Int ?? defaultDailyBackfillDays
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(serverURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.serverURL)
        defaults.set(sampleBackfillDays, forKey: Keys.sampleBackfillDays)
        defaults.set(dailyBackfillDays, forKey: Keys.dailyBackfillDays)
        Keychain.write(Keys.token, Self.normalizeToken(token))
    }

    /// Accepts what people tend to paste: the bare token, "token:me" (the API_TOKENS / secret value),
    /// "API_TOKENS=token:me", or "Bearer token", with stray whitespace or quotes.
    static func normalizeToken(_ raw: String) -> String {
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
        if let range = token.range(of: "API_TOKENS=") { token = String(token[range.upperBound...]) }
        if token.lowercased().hasPrefix("bearer ") { token = String(token.dropFirst(7)) }
        token = String(token.split(separator: ",").first ?? "")
        token = String(token.split(separator: ":").first ?? "")
        return token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Last characters of the token, so it can be checked against the server value without showing it.
    var tokenHint: String {
        token.isEmpty ? "Not set" : "••••\(token.suffix(4)) (\(token.count) chars)"
    }
}

/// Persists HealthKit query anchors so each sync only uploads what changed.
enum SyncState {
    private static let defaults = UserDefaults.standard
    private static let dailyBackfillDoneKey = "sync.dailyBackfillDone"
    private static let lastSyncKey = "sync.lastSyncAt"
    private static let lastProfileKey = "sync.lastProfile"
    private static let recentSyncsKey = "sync.recent"
    private static let backgroundKey = "sync.backgroundDelivery"
    private static let chargingKey = "sync.onlyWhileCharging"
    private static let watchExportKey = "watch.export"
    private static let watchStartKey = "watch.startMinuteOfDay"
    private static let watchSweptKey = "watch.sweptAt"

    static func anchor(for key: String) -> HKQueryAnchor? {
        guard let data = defaults.data(forKey: "anchor.\(key)") else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    static func setAnchor(_ anchor: HKQueryAnchor, for key: String) {
        let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
        defaults.set(data, forKey: "anchor.\(key)")
    }

    static var dailyBackfillDone: Bool {
        get { defaults.bool(forKey: dailyBackfillDoneKey) }
        set { defaults.set(newValue, forKey: dailyBackfillDoneKey) }
    }

    static var lastSyncAt: Date? {
        get { defaults.object(forKey: lastSyncKey) as? Date }
        set { defaults.set(newValue, forKey: lastSyncKey) }
    }

    /// Whether planned sessions are pushed to the watch. Off until the user turns it on, since
    /// turning it on is what triggers the permission prompt.
    static var watchExport: Bool {
        get { defaults.bool(forKey: watchExportKey) }
        set { defaults.set(newValue, forKey: watchExportKey) }
    }

    /// What time of day a scheduled session is put on the watch, as minutes from midnight. The
    /// plan itself carries no time — the coach writes sessions, not appointments — so this is
    /// seeded from the hour the user actually trains and can then be changed.
    static var watchStartMinuteOfDay: Int {
        get { defaults.object(forKey: watchStartKey) as? Int ?? 6 * 60 + 30 }
        set { defaults.set(newValue, forKey: watchStartKey) }
    }

    /// When the watch was last brought in line with the plan, so the settings row can say so.
    static var watchSweptAt: Date? {
        get { defaults.object(forKey: watchSweptKey) as? Date }
        set { defaults.set(newValue, forKey: watchSweptKey) }
    }

    /// Last characteristics upload, so unchanged values are not re-sent on every sync.
    static var lastProfile: ProfilePayload? {
        get {
            guard let data = defaults.data(forKey: lastProfileKey) else { return nil }
            return try? JSONDecoder().decode(ProfilePayload.self, from: data)
        }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: lastProfileKey) }
    }

    /// Drops a metric's anchor when its backfill policy changed. Without this a widened window is
    /// silently ignored: the anchor already points past the history we now want (VO2 max, for
    /// instance, kept a 2024 anchor, so `.all` would have returned nothing).
    static func applyBackfillPolicy(_ backfill: Backfill, for key: String) {
        let current = String(describing: backfill)
        guard defaults.string(forKey: "backfill.\(key)") != current else { return }
        defaults.removeObject(forKey: "anchor.\(key)")
        defaults.set(current, forKey: "backfill.\(key)")
    }

    /// Workouts whose raw heart-rate and speed samples have already been pulled, so the
    /// per-workout backfill runs once per workout instead of on every sync.
    static func workoutDetailDone(_ id: String) -> Bool {
        defaults.bool(forKey: "workoutDetail.\(id)")
    }

    static func markWorkoutDetailDone(_ id: String) {
        defaults.set(true, forKey: "workoutDetail.\(id)")
    }

    /// The last few sync reports, kept on the device so the history tab has something to show
    /// before the server responds (and when it cannot be reached).
    static var recentSyncs: [SyncReport] {
        guard let data = defaults.data(forKey: recentSyncsKey) else { return [] }
        return (try? JSONDecoder().decode([SyncReport].self, from: data)) ?? []
    }

    static func remember(_ report: SyncReport) {
        let kept = ([report] + recentSyncs).prefix(30)
        defaults.set(try? JSONEncoder().encode(Array(kept)), forKey: recentSyncsKey)
    }

    /// Whether HealthKit may wake the app in the background.
    static var backgroundDeliveryEnabled: Bool {
        get { defaults.object(forKey: backgroundKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: backgroundKey) }
    }

    /// Skip background syncs unless the phone is on a charger.
    static var syncOnlyWhileCharging: Bool {
        get { defaults.bool(forKey: chargingKey) }
        set { defaults.set(newValue, forKey: chargingKey) }
    }

    /// Forget all anchors so the next sync re-uploads everything in the backfill window.
    static func reset() {
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("anchor.") || key.hasPrefix("backfill.") || key.hasPrefix("workoutDetail.") {
            defaults.removeObject(forKey: key)
        }
        dailyBackfillDone = false
        lastSyncAt = nil
        lastProfile = nil
    }
}

enum Keychain {
    private static let service = "com.proxyhealthdata.ProxyHealth"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ account: String, _ value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        // Readable in the background after first unlock, for HealthKit background delivery.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
