import Foundation

/// Time window shared by both history charts.
enum HistoryRange: String, CaseIterable, Identifiable {
    case day, week, month
    var id: String { rawValue }

    /// How far back the window reaches.
    var seconds: TimeInterval {
        switch self {
        case .day: return 24 * 3600
        case .week: return 7 * 86400
        case .month: return 30 * 86400
        }
    }

    /// Bucket size for the cost bars (hourly for a day, daily otherwise).
    var bucket: Calendar.Component { self == .day ? .hour : .day }

    func label(_ en: Bool) -> String {
        switch self {
        case .day: return en ? "24h" : "24h"
        case .week: return en ? "7 days" : "7 ngày"
        case .month: return en ? "30 days" : "30 ngày"
        }
    }
}

struct Sample: Codable, Identifiable {
    let t: Date
    let s: Double?  // session (5h) utilization
    let w: Double?  // weekly utilization
    var k: String?  // account key id (nil = legacy pre-multi-account data)
    var id: Date { t }
}

/// Persists usage samples for the history chart and burn-rate math. The most
/// recent 48h keep full ~1/min resolution; older samples are thinned to ~1/hour
/// so a 30-day window stays small enough to load and parse cheaply.
@MainActor
final class HistoryStore {
    static let retention: TimeInterval = 30 * 86400
    private static let fullResWindow: TimeInterval = 48 * 3600
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
        let now = Date()
        let cutoff = now.addingTimeInterval(-Self.retention)
        samples.removeAll { $0.t < cutoff }

        // Beyond the full-resolution window, keep at most one sample per hour
        // per account — enough for a 30-day trend without thousands of points.
        let thinBefore = now.addingTimeInterval(-Self.fullResWindow)
        var kept: [Sample] = []
        var seenHour = Set<String>()
        for sample in samples {
            if sample.t >= thinBefore {
                kept.append(sample)
                continue
            }
            let hour = (sample.t.timeIntervalSince1970 / 3600).rounded(.down)
            let bucket = "\(sample.k ?? "")|\(hour)"
            if seenHour.insert(bucket).inserted { kept.append(sample) }
        }
        samples = kept
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(samples) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
