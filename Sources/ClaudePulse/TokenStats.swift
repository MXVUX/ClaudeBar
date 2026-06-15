import Foundation

struct ModelShare: Identifiable {
    let name: String
    var tokens = 0
    var cost = 0.0
    var id: String { name }
}

struct DayUsage: Identifiable {
    let day: Date
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var cost = 0.0
    // Keyed by display name derived from the transcript's model id, so new
    // models show up automatically without an app update.
    var models: [String: ModelShare] = [:]

    var id: Date { day }
    var total: Int { input + output + cacheRead + cacheWrite }

    init(day: Date) { self.day = day }
}

/// Aggregates token usage and hypothetical API cost from Claude Code's local
/// transcripts (~/.claude/projects/**/*.jsonl). Read-only; nothing leaves the machine.
@MainActor
final class TokenStats: ObservableObject {
    @Published var days: [DayUsage] = []   // last 30 days, ascending
    @Published var hours: [DayUsage] = []  // last 48h, hourly, ascending

    private var timerTask: Task<Void, Never>?
    private var state = ParseState()

    /// Incremental-parse progress carried between reloads: how far each
    /// transcript has been read, which entries were already counted, and the
    /// running per-day / per-hour totals. Transcripts are append-only, so a
    /// reload only reads bytes written since the previous one.
    struct ParseState {
        var offsets: [String: UInt64] = [:]
        var seen = Set<String>()
        var byDay: [Date: DayUsage] = [:]
        var byHour: [Date: DayUsage] = [:]
    }

    init() {
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.reload()
                try? await Task.sleep(nanoseconds: 300_000_000_000)  // 5 min
            }
        }
    }

    var today: DayUsage? {
        guard let last = days.last, Calendar.current.isDateInToday(last.day) else { return nil }
        return last
    }

    /// Bars + total cost for the selected range. A day window uses hourly
    /// buckets; week/month use daily buckets.
    func bars(for range: HistoryRange) -> [DayUsage] {
        let cutoff = Date().addingTimeInterval(-range.seconds)
        let source = range == .day ? hours : days
        return source.filter { $0.day >= cutoff }
    }

    func cost(for range: HistoryRange) -> Double {
        bars(for: range).reduce(0) { $0 + $1.cost }
    }

    func reload() async {
        let started = Date()
        let snapshot = state
        let updated = await Task.detached(priority: .utility) { Self.compute(from: snapshot) }.value
        state = updated
        let dayStart = Calendar.current.startOfDay(for: Date().addingTimeInterval(-29 * 86400))
        days = updated.byDay.values.filter { $0.day >= dayStart }.sorted { $0.day < $1.day }
        hours = updated.byHour.values.sorted { $0.day < $1.day }
        let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
        AppLog.write("token stats: \(days.count) days, parsed in \(elapsed)s")
    }

    nonisolated private static func compute(from previous: ParseState) -> ParseState {
        var state = previous
        let projectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        let cutoff = Date().addingTimeInterval(-31 * 86400)
        let hourCutoff = Date().addingTimeInterval(-48 * 3600)

        // Roll buckets that left their window off the running totals.
        state.byDay = state.byDay.filter { $0.key > cutoff }
        state.byHour = state.byHour.filter { $0.key > hourCutoff }

        var files: [(url: URL, size: UInt64)] = []
        if let enumerator = FileManager.default.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) {
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey])
                if let modified = values?.contentModificationDate, modified > cutoff {
                    files.append((url, UInt64(values?.fileSize ?? 0)))
                }
            }
        }

        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        let calendar = Calendar.current

        for (file, size) in files {
            let offset = state.offsets[file.path] ?? 0
            if size == offset { continue }  // nothing new
            if size < offset {
                // Truncated or rewritten — counted data is unreliable, start over.
                return compute(from: ParseState())
            }
            guard let handle = FileHandle(forReadingAtPath: file.path) else { continue }
            defer { try? handle.close() }
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let data = try? handle.readToEnd(),
                  // The writer may be mid-append — only consume complete lines.
                  let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { continue }
            let chunk = data.prefix(lastNewline + 1)
            state.offsets[file.path] = offset + UInt64(chunk.count)
            guard let text = String(data: chunk, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard line.contains("\"usage\"") else { continue }
                guard
                    let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                        as? [String: Any],
                    object["type"] as? String == "assistant",
                    let message = object["message"] as? [String: Any],
                    let usage = message["usage"] as? [String: Any]
                else { continue }

                // Resumed sessions repeat earlier entries — dedup by message+request id.
                let dedupKey = "\(message["id"] as? String ?? "")|\(object["requestId"] as? String ?? "")"
                if dedupKey != "|" {
                    if state.seen.contains(dedupKey) { continue }
                    state.seen.insert(dedupKey)
                }

                guard let timestamp = object["timestamp"] as? String,
                      let date = isoFrac.date(from: timestamp) ?? isoPlain.date(from: timestamp),
                      date > cutoff else { continue }

                let input = usage["input_tokens"] as? Int ?? 0
                let output = usage["output_tokens"] as? Int ?? 0
                let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                let cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
                let model = message["model"] as? String ?? ""
                let entryCost = Pricing.cost(model: model, input: input, output: output,
                                             cacheRead: cacheRead, cacheWrite: cacheWrite)
                // "<synthetic>" marks locally-generated messages (errors,
                // system notices) — not real API calls; skip in the breakdown.
                let modelName = (!model.isEmpty && !model.hasPrefix("<"))
                    ? Pricing.displayName(model) : nil

                func apply(to stats: inout DayUsage) {
                    stats.input += input
                    stats.output += output
                    stats.cacheRead += cacheRead
                    stats.cacheWrite += cacheWrite
                    stats.cost += entryCost
                    if let modelName {
                        var share = stats.models[modelName] ?? ModelShare(name: modelName)
                        share.tokens += input + output + cacheRead + cacheWrite
                        share.cost += entryCost
                        stats.models[modelName] = share
                    }
                }

                let day = calendar.startOfDay(for: date)
                var dayStats = state.byDay[day] ?? DayUsage(day: day)
                apply(to: &dayStats)
                state.byDay[day] = dayStats

                // Hourly bucket too, for the 24h view (recent entries only).
                if date >= hourCutoff,
                   let hour = calendar.date(from:
                        calendar.dateComponents([.year, .month, .day, .hour], from: date)) {
                    var hourStats = state.byHour[hour] ?? DayUsage(day: hour)
                    apply(to: &hourStats)
                    state.byHour[hour] = hourStats
                }
            }
        }

        return state
    }
}

enum Pricing {
    // USD per 1M tokens (input, output) — Claude API list prices, cached 2026-05.
    // Cache read = 0.1× input; cache write (5-min TTL) = 1.25× input.
    static func rates(for model: String) -> (input: Double, output: Double) {
        if model.contains("fable") { return (10, 50) }
        if model.contains("opus-4-1") || model.contains("opus-4-0") { return (15, 75) }
        if model.contains("opus") { return (5, 25) }
        if model.contains("sonnet") { return (3, 15) }
        if model.contains("haiku-3") { return (0.8, 4) }
        if model.contains("haiku") { return (1, 5) }
        return (5, 25)
    }

    /// "claude-opus-4-8" → "Opus 4.8"; "claude-haiku-4-5-20251001" → "Haiku 4.5".
    /// Works for model ids that don't exist yet — name comes from the id itself.
    static func displayName(_ raw: String) -> String {
        var s = raw
        if let bracket = s.firstIndex(of: "[") { s = String(s[..<bracket]) }
        if s.hasPrefix("claude-") { s = String(s.dropFirst(7)) }
        s = s.replacingOccurrences(of: #"-20\d{6,}$"#, with: "", options: .regularExpression)
        var words: [String] = []
        var version: [String] = []
        for part in s.split(separator: "-") {
            if part.allSatisfy(\.isNumber) {
                version.append(String(part))
            } else {
                words.append(part.prefix(1).uppercased() + part.dropFirst())
            }
        }
        let name = words.joined(separator: " ")
        return version.isEmpty ? name : "\(name) \(version.joined(separator: "."))"
    }

    static func cost(model: String, input: Int, output: Int, cacheRead: Int, cacheWrite: Int) -> Double {
        let r = rates(for: model)
        return (Double(input) * r.input
                + Double(output) * r.output
                + Double(cacheRead) * r.input * 0.1
                + Double(cacheWrite) * r.input * 1.25) / 1_000_000
    }
}

func compactTokens(_ count: Int) -> String {
    switch count {
    case 1_000_000...: return String(format: "%.1fM", Double(count) / 1_000_000)
    case 1_000...: return String(format: "%.0fK", Double(count) / 1_000)
    default: return "\(count)"
    }
}
