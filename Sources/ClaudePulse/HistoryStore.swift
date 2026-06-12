import Foundation

struct Sample: Codable, Identifiable {
    let t: Date
    let s: Double?  // session (5h) utilization
    let w: Double?  // weekly utilization
    var k: String?  // account key id (nil = legacy pre-multi-account data)
    var id: Date { t }
}

/// Persists usage samples (~1/min, capped at 48h) for the sparkline and burn-rate math.
@MainActor
final class HistoryStore {
    private(set) var samples: [Sample] = []
    private let url: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudePulse")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("history.json")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url),
           let loaded = try? decoder.decode([Sample].self, from: data) {
            samples = loaded
        }
        prune()
    }

    func append(key: String, session: Double?, weekly: Double?) {
        let now = Date()
        if let last = samples.last(where: { $0.k == key }),
           now.timeIntervalSince(last.t) < 55 { return }
        samples.append(Sample(t: now, s: session, w: weekly, k: key))
        prune()
        save()
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-48 * 3600)
        samples.removeAll { $0.t < cutoff }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(samples) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
