import Foundation
import Security

struct Profile: Codable, Identifiable {
    let id: String
    var label: String  // empty → display name derived from plan/index
    var credentials: OwnCredentials
}

/// Signed-in accounts, any number of them, in a 0600 JSON file. Replaces the
/// single credentials.json of ≤2.1.x (migrated on first load, with the fixed
/// id "legacy-1" so cached usage can follow it).
enum ProfileStore {
    private static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudePulse")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static var fileURL: URL { directory.appendingPathComponent("profiles.json") }
    private static var legacySingleURL: URL { directory.appendingPathComponent("credentials.json") }

    static func load() -> [Profile] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let profiles = try? decoder.decode([Profile].self, from: data) {
            return profiles
        }
        // Migrate the ≤2.1.x single-credential file.
        if let data = try? Data(contentsOf: legacySingleURL),
           let credentials = try? decoder.decode(OwnCredentials.self, from: data) {
            let migrated = [Profile(id: "legacy-1", label: "", credentials: credentials)]
            save(migrated)
            try? FileManager.default.removeItem(at: legacySingleURL)
            AppLog.write("migrated single credential to profiles.json")
            return migrated
        }
        // Migrate the ≤1.6.1 Keychain item.
        if let credentials = legacyKeychainCredentials() {
            let migrated = [Profile(id: "legacy-1", label: "", credentials: credentials)]
            save(migrated)
            deleteLegacyKeychainItem()
            AppLog.write("migrated keychain credential to profiles.json")
            return migrated
        }
        return []
    }

    static func save(_ profiles: [Profile]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(profiles) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: fileURL.path)
    }

    // MARK: - Legacy Keychain item (pre-1.6.2)

    private static func legacyKeychainCredentials() -> OwnCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ClaudeBar-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(OwnCredentials.self, from: data)
    }

    private static func deleteLegacyKeychainItem() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ClaudeBar-credentials",
        ]
        SecItemDelete(query as CFDictionary)
    }
}
