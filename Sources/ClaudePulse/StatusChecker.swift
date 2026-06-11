import Foundation

/// Polls Anthropic's public status page. Only surfaces in the UI when
/// something is actually wrong — answers "is Claude down, or is it me?".
@MainActor
final class StatusChecker: ObservableObject {
    @Published var indicator = "none"  // none | minor | major | critical
    @Published var summary = ""

    static let pageURL = URL(string: "https://status.anthropic.com")!
    private var timerTask: Task<Void, Never>?

    init() {
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(nanoseconds: 600_000_000_000)  // 10 min
            }
        }
    }

    var hasIssue: Bool { indicator != "none" && !indicator.isEmpty }

    private func check() async {
        guard let url = URL(string: "https://status.anthropic.com/api/v2/status.json"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? [String: Any],
              let level = status["indicator"] as? String
        else { return }
        if level != indicator {
            AppLog.write("anthropic status: \(level)")
        }
        indicator = level
        summary = status["description"] as? String ?? ""
    }
}
