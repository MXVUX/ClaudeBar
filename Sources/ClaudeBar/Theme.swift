import AppKit
import Combine

enum AppTheme: String, CaseIterable {
    case system, light, dark
}

final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published var theme: AppTheme {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: "appTheme")
            apply()
        }
    }

    private init() {
        theme = AppTheme(rawValue: UserDefaults.standard.string(forKey: "appTheme") ?? "system") ?? .system
    }

    func apply() {
        switch theme {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
