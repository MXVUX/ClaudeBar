import Foundation
import Security

struct ClaudeCredentials {
    let accessToken: String
    let expiresAt: Date?
    let subscriptionType: String?
}

enum KeychainTokenProvider {
    /// Attributes-only query — checks existence without touching the secret,
    /// so it never triggers the Keychain permission dialog.
    static func itemExists() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    static func readCredentials() throws -> ClaudeCredentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status == errSecItemNotFound {
                throw UsageError.message(tr("No Claude Code login found in Keychain",
                                            "Không tìm thấy đăng nhập Claude Code trong Keychain"))
            }
            throw UsageError.message(tr("Keychain access denied (code \(status)) — click 'Always Allow'",
                                        "Không đọc được Keychain (mã \(status)) — bấm 'Always Allow'"))
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = json["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String, !token.isEmpty
        else {
            throw UsageError.message(tr("Unexpected Keychain data format",
                                        "Dữ liệu Keychain sai định dạng"))
        }

        var expires: Date?
        if let ms = oauth["expiresAt"] as? Double {
            expires = Date(timeIntervalSince1970: ms / 1000)
        }
        return ClaudeCredentials(
            accessToken: token,
            expiresAt: expires,
            subscriptionType: oauth["subscriptionType"] as? String
        )
    }
}
