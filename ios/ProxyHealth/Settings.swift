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
        static let token = "apiToken"
    }

    static func load() -> SyncSettings {
        let defaults = UserDefaults.standard
        return SyncSettings(
            serverURL: defaults.string(forKey: Keys.serverURL) ?? "http://localhost:3000",
            token: Keychain.read(Keys.token) ?? "",
            sampleBackfillDays: defaults.object(forKey: Keys.sampleBackfillDays) as? Int ?? 7,
            dailyBackfillDays: defaults.object(forKey: Keys.dailyBackfillDays) as? Int ?? 90
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(serverURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.serverURL)
        defaults.set(sampleBackfillDays, forKey: Keys.sampleBackfillDays)
        defaults.set(dailyBackfillDays, forKey: Keys.dailyBackfillDays)
        Keychain.write(Keys.token, token.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Persists HealthKit query anchors so each sync only uploads what changed.
enum SyncState {
    private static let defaults = UserDefaults.standard
    private static let dailyBackfillDoneKey = "sync.dailyBackfillDone"
    private static let lastSyncKey = "sync.lastSyncAt"

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

    /// Forget all anchors so the next sync re-uploads everything in the backfill window.
    static func reset() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("anchor.") {
            defaults.removeObject(forKey: key)
        }
        dailyBackfillDone = false
        lastSyncAt = nil
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
