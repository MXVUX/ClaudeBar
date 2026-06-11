import SwiftUI
import AppKit

@main
struct ClaudeBarApp: App {
    @StateObject private var model = UsageModel()
    @StateObject private var agents = AgentMonitor()
    @StateObject private var tokens = TokenStats()
    @StateObject private var updates = UpdateChecker()

    init() {
        // Single instance: a second launch (e.g. DMG copy + Applications copy)
        // would show two menu bar icons. LaunchServices' list can briefly
        // contain a just-quit instance (which killed relaunch-after-update),
        // so only count entries whose process is actually alive.
        if let bundleID = Bundle.main.bundleIdentifier {
            let myPID = ProcessInfo.processInfo.processIdentifier
            let liveOthers = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier > 0 && $0.processIdentifier != myPID }
                .filter { kill($0.processIdentifier, 0) == 0 }
            if !liveOthers.isEmpty { exit(0) }
        }
        ThemeManager.shared.apply()
        // First launch: the app has no window, so tell the user where it lives.
        if !UserDefaults.standard.bool(forKey: "hasLaunchedBefore") {
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
            Task {
                try? await Task.sleep(for: .seconds(4))
                Notifier.push(
                    title: tr("ClaudeBar is running", "ClaudeBar đang chạy"),
                    body: tr("Look for ✳ in the menu bar (top right) and click it to see your Claude usage.",
                             "Nhìn lên menu bar (góc trên bên phải), bấm icon ✳ để xem usage Claude của bạn."))
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model, agents: agents, tokens: tokens, updates: updates)
        } label: {
            Text(model.menuTitle)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
        }
        .menuBarExtraStyle(.window)
    }
}
