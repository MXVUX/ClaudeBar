import Foundation

struct DayUsage: Identifiable {
    let day: Date
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var cost = 0.0

    var id: Date { day }
    var total: Int { input + output + cacheRead + cacheWrite }

    init(day: Date) { self.day = day }
}

/// Aggregates token usage and hypothetical API cost from Claude Code's local
/// transcripts (~/.claude/projects/**/*.jsonl). Read-only; nothing leaves the machine.
@MainActor
final class TokenStats: ObservableObject {
    @Published var days: [DayUsage] = []  // last 7 days, ascending

    private var timerTask: Task<Void, Never>?

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

    var weekCost: Double { days.reduce(0) { $0 + $1.cost } }

    func reload() async {
        let started = Date()
        let result = await Task.detached(priority: .utility) { Self.compute() }.value
        days = result
        let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
        AppLog.write("token stats: \(result.count) days, parsed in \(elapsed)s")
    }

    nonisolated private static func compute() -> [DayUsage] {
        let projectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        let cutoff = Date().addingTimeInterval(-8 * 86400)

        var files: [URL] = []
        if let enumerator = FileManager.default.enumerator(
            at: projectsDir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                if let modified, modified > cutoff { files.append(url) }
            }
        }

        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        let calendar = Calendar.current

        var seen = Set<String>()
        var byDay: [Date: DayUsage] = [:]

        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let text = String(data: data, encoding: .utf8) else { continue }
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
                    if seen.contains(dedupKey) { continue }
                    seen.insert(dedupKey)
                }

                guard let timestamp = object["timestamp"] as? String,
                      let date = isoFrac.date(from: timestamp) ?? isoPlain.date(from: timestamp),
                      date > cutoff else { continue }

                let day = calendar.startOfDay(for: date)
                var stats = byDay[day] ?? DayUsage(day: day)
                let input = usage["input_tokens"] as? Int ?? 0
                let output = usage["output_tokens"] as? Int ?? 0
                let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                let cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
                stats.input += input
                stats.output += output
                stats.cacheRead += cacheRead
                stats.cacheWrite += cacheWrite
                stats.cost += Pricing.cost(model: message["model"] as? String ?? "",
                                           input: input, output: output,
                                           cacheRead: cacheRead, cacheWrite: cacheWrite)
                byDay[day] = stats
            }
        }

        let weekStart = calendar.startOfDay(for: Date().addingTimeInterval(-6 * 86400))
        return byDay.values.filter { $0.day >= weekStart }.sorted { $0.day < $1.day }
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
