import Foundation
import CryptoKit
import Security

struct OwnCredentials: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

/// "Sign in with Claude" — the same OAuth flow Claude Code uses (PKCE +
/// manual code paste), but the resulting tokens are ClaudeBar's own, stored
/// in a separate Keychain item and refreshed independently. Claude Code's
/// session is never touched.
enum ClaudeAuth {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    static let scopes = "org:create_api_key user:profile user:inference"
    private static let keychainService = "ClaudeBar-credentials"

    struct PendingFlow {
        let verifier: String
        let state: String
        let url: URL
    }

    // MARK: - Flow

    static func beginFlow() -> PendingFlow {
        let verifier = randomURLSafe(32)
        let state = randomURLSafe(32)
        let challenge = base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        var components = URLComponents(string: "https://claude.ai/oauth/authorize")!
        components.queryItems = [
            .init(name: "code", value: "true"),
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scopes),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        return PendingFlow(verifier: verifier, state: state, url: components.url!)
    }

    /// The callback page shows the code as `<code>#<state>`.
    static func exchange(pasted: String, flow: PendingFlow) async throws -> OwnCredentials {
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "#", maxSplits: 1)
        guard let codePart = parts.first, !codePart.isEmpty else {
            throw UsageError.message(tr("That code looks empty", "Code dán vào đang trống"))
        }
        return try await tokenRequest([
            "grant_type": "authorization_code",
            "code": String(codePart),
            "state": parts.count > 1 ? String(parts[1]) : flow.state,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "code_verifier": flow.verifier,
        ])
    }

    static func refresh(_ credentials: OwnCredentials) async throws -> OwnCredentials {
        try await tokenRequest([
            "grant_type": "refresh_token",
            "refresh_token": credentials.refreshToken,
            "client_id": clientID,
        ])
    }

    private static func tokenRequest(_ body: [String: Any]) async throws -> OwnCredentials {
        var request = URLRequest(url: URL(string: "https://console.anthropic.com/v1/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String,
              let refreshToken = json["refresh_token"] as? String
        else {
            AppLog.write("oauth token request failed: HTTP \(status)")
            throw UsageError.message(tr("Sign-in failed (HTTP \(status)) — try again",
                                        "Đăng nhập thất bại (HTTP \(status)) — thử lại nhé"))
        }
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        return OwnCredentials(accessToken: access,
                              refreshToken: refreshToken,
                              expiresAt: Date().addingTimeInterval(expiresIn - 60))
    }

    // MARK: - Keychain (ClaudeBar's own item — created by us, no prompt)

    static func load() -> OwnCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
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

    static func save(_ credentials: OwnCredentials) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(credentials) else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    static func signOut() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Helpers

    private static func randomURLSafe(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return base64url(Data(bytes))
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
