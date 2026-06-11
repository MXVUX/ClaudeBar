import Foundation
import Combine

enum AppLanguage: String, CaseIterable {
    case en, vi
}

final class L10n: ObservableObject {
    static let shared = L10n()

    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "appLanguage") }
    }

    private init() {
        language = AppLanguage(
            rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "en") ?? .en
    }
}

/// English / Vietnamese string pick. Universal tech terms (session, token,
/// cache, burn rate, reset, model…) stay English in both languages.
func tr(_ en: String, _ vi: String) -> String {
    L10n.shared.language == .vi ? vi : en
}
