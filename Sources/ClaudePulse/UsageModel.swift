import Foundation

// MARK: - API response

struct UsageBucket: Decodable {
    let utilization: Double?
    let resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        utilization = try c.decodeIfPresent(Double.self, forKey: .utilization)
        if let raw = try c.decodeIfPresent(String.self, forKey: .resetsAt) {
            resetsAt = Self.iso.date(from: raw) ?? Self.isoPlain.date(from: raw)
        } else {
            resetsAt = nil
        }
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let isoPlain = ISO8601DateFormatter()
}

struct ExtraUsage: Decodable {
    let isEnabled: Bool?
    let monthlyLimit: Double?
    let usedCredits: Double?
    let utilization: Double?
    let currency: String?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
        case currency
    }
}

struct UsageResponse: Decodable {
    let fiveHour: UsageBucket?
    let sevenDay: UsageBucket?
    let sevenDayOpus: UsageBucket?
    let sevenDaySonnet: UsageBucket?
    // Enterprise: "Claude Design — included allowance" ships under this codename.
    let omelettePromotional: UsageBucket?
    let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case omelettePromotional = "omelette_promotional"
        case extraUsage = "extra_usage"
    }

    /// Enterprise seats have no %-based session/weekly limits — the spend
    /// limit (extra_usage, in cents) is the primary number.
    var isSpendBased: Bool {
        fiveHour?.utilization == nil && sevenDay?.utilization == nil
            && extraUsage?.isEnabled == true
    }

    /// Free or unknown plans can return a response with nothing to show.
    var hasAnyDisplayable: Bool {
        fiveHour?.utilization != nil || sevenDay?.utilization != nil
            || sevenDaySonnet?.utilization != nil || sevenDayOpus?.utilization != nil
            || omelettePromotional?.utilization != nil || extraUsage?.isEnabled == true
    }
}

// MARK: - Model

enum AccountKey: Hashable, Identifiable {
    case claudeCode
    case profile(String)

    var id: String {
        switch self {
        case .claudeCode: return "cc"
        case .profile(let pid): return pid
        }
    }
}

@MainActor
final class UsageModel: ObservableObject {
    @Published var usage: UsageResponse?
    @Published var errorMessage: String?
    @Published var lastUpdated: Date?
    @Published var subscriptionType: String?
    @Published var samples: [Sample] = []
    /// Signed-in accounts (any number). Mutations persist automatically.
    @Published var profiles: [Profile] = ProfileStore.load() {
        didSet { ProfileStore.save(profiles) }
    }
    // Sign-in flow state lives here, not in the view: the popover closes the
    // moment the user clicks over to the browser, and view @State (including
    // the PKCE verifier) would be destroyed with it.
    @Published var pendingAuthFlow: ClaudeAuth.PendingFlow?
    @Published var pendingAuthCode = ""
    @Published var hasClaudeCodeAccount = KeychainTokenProvider.itemExists()
    @Published var selectedKey: AccountKey = .claudeCode {
        didSet {
            guard oldValue != selectedKey else { return }
            UserDefaults.standard.set(selectedKey.id, forKey: "selectedAccount")
            showCachedUsage()
            errorMessage = nil
            Task { await self.refresh() }
        }
    }

    /// Last known data for the selected account — switching tabs (or a fresh
    /// launch) shows it instantly instead of a blank wait for the next fetch.
    private func showCachedUsage() {
        usage = usageCache[selectedKey.id]
        lastUpdated = UserDefaults.standard
            .object(forKey: "usageCacheAt.\(selectedKey.id)") as? Date
        switch selectedKey {
        case .claudeCode:
            subscriptionType = ccSubscription
        case .profile(let pid):
            subscriptionType = usageCache[pid]?.isSpendBased == true ? "Enterprise" : nil
        }
    }

    // Keyed by account identity (profile id), not by slot — switching the
    // underlying account can never show another account's cached numbers.
    private var usageCache: [String: UsageResponse] = [:]
    private var lastFetchedKey: AccountKey?
    private var ccSubscription: String? = UserDefaults.standard.string(forKey: "ccSubscription")
    // In-memory token cache: reading the Keychain every poll would re-fire
    // the permission dialog for users whose Always Allow didn't stick.
    private var ccCredentialsCache: ClaudeCredentials?

    var availableKeys: [AccountKey] {
        var keys: [AccountKey] = []
        if hasClaudeCodeAccount { keys.append(.claudeCode) }
        keys.append(contentsOf: profiles.map { .profile($0.id) })
        return keys
    }

    func label(for key: AccountKey) -> String {
        switch key {
        case .claudeCode:
            return ccSubscription?.capitalized ?? "Claude Code"
        case .profile(let pid):
            guard let index = profiles.firstIndex(where: { $0.id == pid }) else { return "?" }
            let profile = profiles[index]
            if !profile.label.isEmpty { return profile.label }
            if usageCache[pid]?.isSpendBased == true {
                let priorEnterprise = profiles.prefix(index).filter {
                    $0.label.isEmpty && usageCache[$0.id]?.isSpendBased == true
                }.count
                return priorEnterprise == 0 ? "Enterprise" : "Enterprise \(priorEnterprise + 1)"
            }
            return "\(tr("Account", "Tài khoản")) \(index + 1)"
        }
    }

    func addProfile(credentials: OwnCredentials) {
        let profile = Profile(id: UUID().uuidString, label: "", credentials: credentials)
        profiles.append(profile)
        selectedKey = .profile(profile.id)
    }

    func removeProfile(_ pid: String) {
        profiles.removeAll { $0.id == pid }
        usageCache[pid] = nil
        UserDefaults.standard.removeObject(forKey: "usageCache.\(pid)")
        UserDefaults.standard.removeObject(forKey: "usageCacheAt.\(pid)")
        if selectedKey == .profile(pid) {
            if let first = availableKeys.first {
                selectedKey = first
            } else {
                usage = nil
            }
        }
    }

    // Menu bar display options
    @Published var showSession = UserDefaults.standard.object(forKey: "showSession") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showSession, forKey: "showSession") }
    }
    @Published var showWeekly = UserDefaults.standard.object(forKey: "showWeekly") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showWeekly, forKey: "showWeekly") }
    }
    @Published var showCountdown = UserDefaults.standard.bool(forKey: "showCountdown") {
        didSet { UserDefaults.standard.set(showCountdown, forKey: "showCountdown") }
    }

    private let history = HistoryStore()

    var refreshInterval: TimeInterval {
        // The usage endpoint rate-limits around 1 req/min, so 60s is the floor.
        get { max(60, UserDefaults.standard.double(forKey: "refreshInterval").nonZero ?? 60) }
        set {
            UserDefaults.standard.set(newValue, forKey: "refreshInterval")
            restartTimer()
        }
    }

    private var timerTask: Task<Void, Never>?

    init() {
        samples = history.samples
        migrateLegacyAccountKeys()
        // Restore per-account usage caches for instant display.
        for key in ["cc"] + profiles.map(\.id) {
            if let data = UserDefaults.standard.data(forKey: "usageCache.\(key)"),
               let cached = try? JSONDecoder().decode(UsageResponse.self, from: data) {
                usageCache[key] = cached
            }
        }
        // Restore selection; fall back to the first available account.
        let stored = UserDefaults.standard.string(forKey: "selectedAccount")
        if stored == "cc", hasClaudeCodeAccount {
            selectedKey = .claudeCode
        } else if let stored, profiles.contains(where: { $0.id == stored }) {
            selectedKey = .profile(stored)
        } else if !hasClaudeCodeAccount, let first = profiles.first {
            selectedKey = .profile(first.id)
        }
        showCachedUsage()
        Notifier.requestAuthorization()
        restartTimer()
    }

    /// ≤2.1.x stored cache/selection under slot names — remap once.
    private func migrateLegacyAccountKeys() {
        let ud = UserDefaults.standard
        let pairs = [("claudeCode", "cc"), ("ownLogin", "legacy-1")]
        for (old, new) in pairs {
            if let data = ud.data(forKey: "usageCache.\(old)") {
                ud.set(data, forKey: "usageCache.\(new)")
                ud.removeObject(forKey: "usageCache.\(old)")
            }
            if let at = ud.object(forKey: "usageCacheAt.\(old)") {
                ud.set(at, forKey: "usageCacheAt.\(new)")
                ud.removeObject(forKey: "usageCacheAt.\(old)")
            }
        }
        switch ud.string(forKey: "selectedAccount") {
        case "claudeCode": ud.set("cc", forKey: "selectedAccount")
        case "ownLogin": ud.set("legacy-1", forKey: "selectedAccount")
        default: break
        }
    }

    var menuTitle: String {
        guard let u = usage else {
            return errorMessage == nil ? "✳ …" : "✳ –"
        }
        if !u.hasAnyDisplayable { return "✳" }
        if u.isSpendBased, let extra = u.extraUsage, let limit = extra.monthlyLimit {
            let used = extra.usedCredits ?? 0
            let warn = limit > 0 && used / limit >= 0.9 ? "❗" : ""
            return "✳ \(warn)$\(Self.compactDollars(used))/$\(Self.compactDollars(limit))"
        }
        var parts: [String] = []
        if showSession { parts.append(Self.percentText(u.fiveHour?.utilization)) }
        if showWeekly { parts.append(Self.percentText(u.sevenDay?.utilization)) }
        if showCountdown, let resets = u.fiveHour?.resetsAt {
            parts.append(Self.shortCountdown(to: resets))
        }
        let warn = max(u.fiveHour?.utilization ?? 0, u.sevenDay?.utilization ?? 0) >= 90 ? "❗" : ""
        return parts.isEmpty ? "✳\(warn)" : "✳ \(warn)\(parts.joined(separator: " · "))"
    }

    static func shortCountdown(to date: Date) -> String {
        let seconds = max(0, date.timeIntervalSinceNow)
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        return h > 0 ? "\(h)h\(String(format: "%02d", m))" : "\(m)m"
    }

    // MARK: - Burn rate & forecast (session bucket)

    /// %/hour over recent samples within the current 5h window; nil when not enough data.
    var sessionBurnRate: Double? {
        guard let resets = usage?.fiveHour?.resetsAt else { return nil }
        let periodStart = resets.addingTimeInterval(-5 * 3600)
        let windowStart = max(periodStart, Date().addingTimeInterval(-45 * 60))
        let window = samples.filter { $0.t >= windowStart && $0.s != nil }
        guard let first = window.first, let last = window.last,
              let firstValue = first.s, let lastValue = last.s,
              last.t.timeIntervalSince(first.t) >= 8 * 60
        else { return nil }
        let hours = last.t.timeIntervalSince(first.t) / 3600
        let rate = (lastValue - firstValue) / hours
        return rate > 0 ? rate : 0
    }

    struct Forecast {
        let text: String
        let isWarning: Bool
        /// Where usage is projected to land at reset time — drawn as a
        /// translucent extension of the session progress bar.
        let projectedAtReset: Double
    }

    var sessionForecast: Forecast? {
        guard let rate = sessionBurnRate,
              let current = usage?.fiveHour?.utilization,
              let resets = usage?.fiveHour?.resetsAt
        else { return nil }
        let rateText = String(format: "%.1f%%/h", rate)
        let hoursLeft = max(0, resets.timeIntervalSinceNow) / 3600
        let projected = current + rate * hoursLeft

        guard rate > 0.5 else {
            return Forecast(text: tr("Burn rate ~\(rateText) — steady", "Burn rate ~\(rateText) — ổn định"),
                            isWarning: false, projectedAtReset: projected)
        }
        if projected >= 100 {
            let hoursTo100 = (100 - current) / rate
            let hitDate = Date().addingTimeInterval(hoursTo100 * 3600)
            let time = hitDate.formatted(date: .omitted, time: .shortened)
            let early = max(0, resets.timeIntervalSince(hitDate))
            let h = Int(early) / 3600
            let m = (Int(early) % 3600) / 60
            let earlyText = h > 0 ? "\(h)h \(m)m" : "\(m)m"
            return Forecast(
                text: tr("\(rateText) → hits 100% at ~\(time), \(earlyText) before reset",
                         "\(rateText) → chạm 100% lúc ~\(time), trước reset \(earlyText)"),
                isWarning: true, projectedAtReset: projected)
        }
        return Forecast(
            text: tr("\(rateText) → ~\(Int(projected))% by reset — safe",
                     "\(rateText) → dự kiến ~\(Int(projected))% lúc reset — an toàn"),
            isWarning: false, projectedAtReset: projected)
    }

    static func percentText(_ value: Double?) -> String {
        guard let value else { return "–" }
        return "\(Int(value.rounded()))%"
    }

    /// Cents → "$80" or "$12.50" (drops trailing .00 to save menu bar space).
    static func compactDollars(_ cents: Double) -> String {
        let dollars = cents / 100
        return dollars == dollars.rounded()
            ? String(format: "%.0f", dollars)
            : String(format: "%.2f", dollars)
    }

    func restartTimer() {
        timerTask?.cancel()
        let interval = refreshInterval
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private var rateLimitedUntil: Date?

    func refresh(force: Bool = false) async {
        if let until = rateLimitedUntil, !force {
            if Date() < until { return }
            rateLimitedUntil = nil
        }
        if force { rateLimitedUntil = nil }
        // Pin the account for this whole fetch: the user may switch tabs
        // mid-flight, and results must never land under another account.
        let key = selectedKey
        do {
            let token = try await resolveToken(for: key)
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw UsageError.message("Invalid response")
            }
            if http.statusCode == 401 {
                ccCredentialsCache = nil  // stale cache — re-read Keychain next poll
                throw UsageError.message(tr("Token expired — open Claude Code to refresh it",
                                            "Token hết hạn — mở Claude Code để làm mới"))
            }
            if http.statusCode == 429 {
                // Routine: Claude Code shares this endpoint's quota. Skip
                // quietly and retry — stale-by-a-minute data is fine.
                let retryAfter = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 90
                rateLimitedUntil = Date().addingTimeInterval(max(retryAfter, 60))
                AppLog.write("rate limited, retry in \(Int(max(retryAfter, 60)))s")
                return
            }
            guard http.statusCode == 200 else {
                throw UsageError.message(tr("API error HTTP \(http.statusCode)",
                                            "API lỗi HTTP \(http.statusCode)"))
            }
            let previous = usageCache[key.id]
            let fresh = try JSONDecoder().decode(UsageResponse.self, from: data)
            usageCache[key.id] = fresh
            UserDefaults.standard.set(data, forKey: "usageCache.\(key.id)")
            UserDefaults.standard.set(Date(), forKey: "usageCacheAt.\(key.id)")
            if key == selectedKey {
                usage = fresh
                lastUpdated = Date()
                errorMessage = nil
            }

            history.append(session: fresh.fiveHour?.utilization,
                           weekly: fresh.sevenDay?.utilization)
            samples = history.samples
            // Only compare within the same account — switching tabs must not
            // fire threshold notifications.
            if lastFetchedKey == key, let previous {
                checkAlerts(previous: previous, current: fresh)
            }
            lastFetchedKey = key
            AppLog.write("fetch ok [\(key.id)]: session=\(fresh.fiveHour?.utilization ?? -1) weekly=\(fresh.sevenDay?.utilization ?? -1) spend=\(fresh.extraUsage?.usedCredits ?? -1)")
        } catch {
            let msg = (error as? UsageError)?.text ?? error.localizedDescription
            if key == selectedKey { errorMessage = msg }
            // A denied Keychain prompt would otherwise re-prompt every poll —
            // back off; the manual refresh button still tries immediately.
            if msg.contains("Always Allow") {
                rateLimitedUntil = Date().addingTimeInterval(900)
            }
            AppLog.write("fetch error: \(msg)")
        }
    }

    // MARK: - Credential resolution

    /// Token for the given account.
    private func resolveToken(for key: AccountKey) async throws -> String {
        switch key {
        case .profile(let pid):
            guard let index = profiles.firstIndex(where: { $0.id == pid }) else {
                throw UsageError.message(tr("Signed out — sign in again in Settings",
                                            "Đã đăng xuất — đăng nhập lại trong Cài đặt"))
            }
            var credentials = profiles[index].credentials
            if credentials.expiresAt < Date().addingTimeInterval(120) {
                do {
                    credentials = try await ClaudeAuth.refresh(credentials)
                    profiles[index].credentials = credentials  // didSet persists
                    AppLog.write("profile \(pid) token refreshed")
                } catch {
                    throw UsageError.message(tr("Sign-in expired — sign in again in Settings",
                                                "Phiên đăng nhập hết hạn — đăng nhập lại trong Cài đặt"))
                }
            }
            if key == selectedKey {
                subscriptionType = usageCache[pid]?.isSpendBased == true ? "Enterprise" : nil
            }
            return credentials.accessToken
        case .claudeCode:
            if let cached = ccCredentialsCache, let expires = cached.expiresAt,
               expires > Date().addingTimeInterval(300) {
                if key == selectedKey { subscriptionType = cached.subscriptionType ?? ccSubscription }
                return cached.accessToken
            }
            let cred = try KeychainTokenProvider.readCredentials()
            // Claude Code switched accounts → its cached usage is another
            // account's data; drop it.
            if let old = ccSubscription, let new = cred.subscriptionType, old != new {
                usageCache["cc"] = nil
                UserDefaults.standard.removeObject(forKey: "usageCache.cc")
                UserDefaults.standard.removeObject(forKey: "usageCacheAt.cc")
                if selectedKey == .claudeCode { usage = nil }
                AppLog.write("claude code account changed (\(old) → \(new)) — cache cleared")
            }
            ccCredentialsCache = cred
            hasClaudeCodeAccount = true
            ccSubscription = cred.subscriptionType
            UserDefaults.standard.set(cred.subscriptionType, forKey: "ccSubscription")
            if key == selectedKey { subscriptionType = cred.subscriptionType }
            return cred.accessToken
        }
    }

    // MARK: - Threshold notifications

    private func checkAlerts(previous: UsageResponse?, current: UsageResponse) {
        guard let previous else { return }
        crossingAlerts(name: "Session",
                       old: previous.fiveHour?.utilization,
                       new: current.fiveHour?.utilization)
        crossingAlerts(name: "Weekly",
                       old: previous.sevenDay?.utilization,
                       new: current.sevenDay?.utilization)
        // Session reset: a big drop means a fresh 5h window.
        if let old = previous.fiveHour?.utilization,
           let new = current.fiveHour?.utilization,
           old >= 30, new < old - 25 {
            Notifier.push(title: tr("Session limit reset 🎉", "Session limit đã reset 🎉"),
                          body: tr("Usage is back to \(Int(new.rounded()))% — fresh window.",
                                   "Usage về \(Int(new.rounded()))% — cửa sổ 5h mới."))
        }
    }

    private func crossingAlerts(name: String, old: Double?, new: Double?) {
        guard let old, let new else { return }
        for threshold in [80.0, 95.0] where old < threshold && new >= threshold {
            Notifier.push(title: tr("Claude \(name) at \(Int(new.rounded()))%",
                                    "Claude \(name) đạt \(Int(new.rounded()))%"),
                          body: tr("Crossed the \(Int(threshold))% \(name.lowercased()) limit.",
                                   "Đã vượt ngưỡng \(Int(threshold))% của \(name.lowercased()) limit."))
        }
    }
}

enum UsageError: Error {
    case message(String)
    var text: String {
        switch self { case .message(let m): return m }
    }
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}

// Simple file log so the build can be verified headlessly.
enum AppLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ClaudePulse.log")

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
