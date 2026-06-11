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
        // Read via Apple's `security` CLI: the Claude Code item's partition
        // list admits Apple-signed tools silently, while direct SecItem reads
        // from a self-signed app re-prompt on every updated binary.
        let data = try readViaSecurityCLI() ?? readViaSecItem()

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

    private static func readViaSecurityCLI() throws -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil  // fall back to SecItem
        }
        process.waitUntilExit()
        if process.terminationStatus == 44 {  // errSecItemNotFound
            throw UsageError.message(tr("No Claude Code login found in Keychain",
                                        "Không tìm thấy đăng nhập Claude Code trong Keychain"))
        }
        guard process.terminationStatus == 0 else { return nil }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return Data(text.utf8)
    }

    private static func readViaSecItem() throws -> Data {
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
        return data
    }
}
