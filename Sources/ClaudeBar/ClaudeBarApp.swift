import SwiftUI
import AppKit
import ServiceManagement

@main
struct ClaudeBarApp: App {
    @StateObject private var model = UsageModel()
    @StateObject private var agents = AgentMonitor()
    @StateObject private var tokens = TokenStats()
    @StateObject private var updates = UpdateChecker()
    @StateObject private var status = StatusChecker()

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
        // Renamed-app self-heal: an old (pre-rename) updater installs us into
        // its legacy ClaudeBar.app path — relocate to ClaudePulse.app once.
        let bundlePath = Bundle.main.bundlePath
        if (bundlePath as NSString).lastPathComponent == "ClaudeBar.app" {
            let dir = (bundlePath as NSString).deletingLastPathComponent
            let newPath = (dir as NSString).appendingPathComponent("ClaudePulse.app")
            let pid = ProcessInfo.processInfo.processIdentifier
            let script = """
            #!/bin/bash
            exec >> "$HOME/Library/Logs/ClaudePulse.log" 2>&1
            echo "relocate: waiting for pid \(pid)"
            while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.3; done
            /bin/rm -rf "\(newPath)"
            /usr/bin/ditto "\(bundlePath)" "\(newPath)" && /bin/rm -rf "\(bundlePath)"
            /usr/bin/xattr -dr com.apple.quarantine "\(newPath)" 2>/dev/null
            /usr/bin/open "\(newPath)"
            echo "relocate: done"
            """
            let scriptPath = "/tmp/claudepulse-relocate.sh"
            try? script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            let relocator = Process()
            relocator.executableURL = URL(fileURLWithPath: "/bin/bash")
            relocator.arguments = [scriptPath]
            try? relocator.run()
            exit(0)
        }

        // Migrate Application Support data from the pre-rename folder.
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let legacyDir = appSupport.appendingPathComponent("ClaudeBar")
        let currentDir = appSupport.appendingPathComponent("ClaudePulse")
        if fm.fileExists(atPath: legacyDir.path), !fm.fileExists(atPath: currentDir.path) {
            try? fm.moveItem(at: legacyDir, to: currentDir)
        }

        ThemeManager.shared.apply()

        // The login item registration points at the old app path after a
        // rename — re-register if the user had it on.
        if UserDefaults.standard.bool(forKey: "launchAtLoginOn"),
           SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }

        // First launch: the app has no window, so tell the user where it lives.
        if !UserDefaults.standard.bool(forKey: "hasLaunchedBefore") {
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
            Task {
                try? await Task.sleep(for: .seconds(4))
                Notifier.push(
                    title: tr("ClaudePulse is running", "ClaudePulse đang chạy"),
                    body: tr("Look for ✳ in the menu bar (top right) and click it to see your Claude usage.",
                             "Nhìn lên menu bar (góc trên bên phải), bấm icon ✳ để xem usage Claude của bạn."))
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model, agents: agents, tokens: tokens,
                        updates: updates, status: status)
        } label: {
            Text(model.menuTitle)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
        }
        .menuBarExtraStyle(.window)
    }
}
