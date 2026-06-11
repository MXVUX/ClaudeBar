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
    let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage = "extra_usage"
    }
}

// MARK: - Model

@MainActor
final class UsageModel: ObservableObject {
    @Published var usage: UsageResponse?
    @Published var errorMessage: String?
    @Published var lastUpdated: Date?
    @Published var subscriptionType: String?
    @Published var samples: [Sample] = []

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
        Notifier.requestAuthorization()
        restartTimer()
    }

    var menuTitle: String {
        guard let u = usage else {
            return errorMessage == nil ? "✳ …" : "✳ –"
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

    var sessionForecast: (text: String, isWarning: Bool)? {
        guard let rate = sessionBurnRate,
              let current = usage?.fiveHour?.utilization,
              let resets = usage?.fiveHour?.resetsAt
        else { return nil }
        let rateText = String(format: "%.1f%%/h", rate)
        guard rate > 0.5 else {
            return (tr("Burn rate ~\(rateText) — steady", "Burn rate ~\(rateText) — ổn định"), false)
        }
        let hoursTo100 = (100 - current) / rate
        let hitDate = Date().addingTimeInterval(hoursTo100 * 3600)
        if hitDate < resets {
            let time = hitDate.formatted(date: .omitted, time: .shortened)
            return (tr("Burn rate \(rateText) → hits 100% at ~\(time)",
                       "Burn rate \(rateText) → chạm 100% lúc ~\(time)"), true)
        }
        return (tr("Burn rate \(rateText) — safe until reset",
                   "Burn rate \(rateText) — an toàn tới giờ reset"), false)
    }

    static func percentText(_ value: Double?) -> String {
        guard let value else { return "–" }
        return "\(Int(value.rounded()))%"
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

    func refresh() async {
        if let until = rateLimitedUntil {
            if Date() < until { return }
            rateLimitedUntil = nil
        }
        do {
            let cred = try KeychainTokenProvider.readCredentials()
            subscriptionType = cred.subscriptionType
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            request.setValue("Bearer \(cred.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw UsageError.message("Invalid response")
            }
            if http.statusCode == 401 {
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
            let previous = usage
            let fresh = try JSONDecoder().decode(UsageResponse.self, from: data)
            usage = fresh
            lastUpdated = Date()
            errorMessage = nil

            history.append(session: fresh.fiveHour?.utilization,
                           weekly: fresh.sevenDay?.utilization)
            samples = history.samples
            checkAlerts(previous: previous, current: fresh)
            AppLog.write("fetch ok: session=\(fresh.fiveHour?.utilization ?? -1) weekly=\(fresh.sevenDay?.utilization ?? -1)")
        } catch {
            let msg = (error as? UsageError)?.text ?? error.localizedDescription
            errorMessage = msg
            AppLog.write("fetch error: \(msg)")
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
        .appendingPathComponent("Library/Logs/ClaudeBar.log")

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
