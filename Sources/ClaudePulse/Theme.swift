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
        // NSApplication.shared (not the NSApp global): during SwiftUI's
        // App.init the NSApp global is still nil and unwrapping it crashed
        // v1.7.0 at launch. .shared creates the application object on demand.
        let app = NSApplication.shared
        switch theme {
        case .system: app.appearance = nil
        case .light: app.appearance = NSAppearance(named: .aqua)
        case .dark: app.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
