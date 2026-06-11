import Foundation
import AppKit

struct AvailableUpdate {
    let version: String
    let dmgURL: URL
    let pageURL: URL
}

/// Checks GitHub Releases for a newer version and can self-update: download
/// the DMG, stage the new bundle, then a detached script swaps it in after
/// the app quits and relaunches it.
@MainActor
final class UpdateChecker: ObservableObject {
    enum State: Equatable { case idle, checking, downloading, failed(String) }

    @Published var available: AvailableUpdate?
    @Published var state: State = .idle
    @Published var lastChecked: Date?

    @Published var autoCheck: Bool = UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoCheck, forKey: "autoCheckUpdates")
            if autoCheck { startTimer() } else { timerTask?.cancel() }
        }
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private var timerTask: Task<Void, Never>?
    private var notifiedVersion: String?
    private static let repoAPI = "https://api.github.com/repos/MXVUX/ClaudeBar/releases/latest"

    init() {
        if autoCheck { startTimer() }
    }

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)  // let launch settle
            while !Task.isCancelled {
                await self?.check(silent: true)
                // Hidden hook so the full pipeline is testable headlessly.
                if ProcessInfo.processInfo.environment["CLAUDEBAR_FORCE_UPDATE"] == "1",
                   self?.available != nil {
                    await self?.updateNow()
                }
                try? await Task.sleep(nanoseconds: 6 * 3600 * 1_000_000_000)
            }
        }
    }

    func check(silent: Bool) async {
        state = .checking
        defer {
            lastChecked = Date()
            if state == .checking { state = .idle }
        }
        var request = URLRequest(url: URL(string: Self.repoAPI)!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String
        else {
            if !silent { state = .failed(tr("Could not reach GitHub", "Không kết nối được GitHub")) }
            return
        }

        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        AppLog.write("update check: latest=\(latest) current=\(Self.currentVersion)")

        let assets = json["assets"] as? [[String: Any]] ?? []
        let dmg = assets
            .first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }?["browser_download_url"] as? String
        let page = json["html_url"] as? String ?? "https://github.com/MXVUX/ClaudeBar/releases"

        guard Self.isNewer(latest, than: Self.currentVersion),
              let dmg, let dmgURL = URL(string: dmg), let pageURL = URL(string: page)
        else {
            available = nil
            return
        }
        available = AvailableUpdate(version: latest, dmgURL: dmgURL, pageURL: pageURL)
        if notifiedVersion != latest {
            notifiedVersion = latest
            Notifier.push(
                title: tr("ClaudeBar \(latest) is available", "Có ClaudeBar \(latest) mới"),
                body: tr("Click ✳ in the menu bar and press Update.",
                         "Bấm icon ✳ trên menu bar rồi bấm Cập nhật."))
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    func updateNow() async {
        guard let update = available, state != .downloading else { return }
        state = .downloading
        let dmgPath = "/tmp/ClaudeBar-update.dmg"
        let mount = "/tmp/ClaudeBar-update-mnt"
        let staging = "/tmp/ClaudeBar-update.app"
        do {
            let (tmpFile, _) = try await URLSession.shared.download(from: update.dmgURL)
            try? FileManager.default.removeItem(atPath: dmgPath)
            try FileManager.default.moveItem(at: tmpFile, to: URL(fileURLWithPath: dmgPath))

            // A stale mount from a previously failed run would block attach.
            try? runTool("/usr/bin/hdiutil", ["detach", mount, "-quiet", "-force"])
            try runTool("/usr/bin/hdiutil", ["attach", dmgPath, "-nobrowse", "-quiet", "-mountpoint", mount])
            do {
                try? FileManager.default.removeItem(atPath: staging)
                try runTool("/usr/bin/ditto", ["\(mount)/ClaudeBar.app", staging])
            } catch {
                try? runTool("/usr/bin/hdiutil", ["detach", mount, "-quiet"])
                throw error
            }
            try? runTool("/usr/bin/hdiutil", ["detach", mount, "-quiet"])
            // Strip quarantine so Gatekeeper doesn't re-block the swapped copy.
            try? runTool("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staging])

            // Install over ourselves — unless we're running from a DMG, a
            // translocated path, or anywhere read-only; then /Applications.
            var dest = Bundle.main.bundlePath
            let parent = (dest as NSString).deletingLastPathComponent
            if dest.contains("/AppTranslocation/") || dest.hasPrefix("/Volumes/")
                || !FileManager.default.isWritableFile(atPath: parent) {
                dest = "/Applications/ClaudeBar.app"
                AppLog.write("update: unwritable location, installing to \(dest)")
            }

            let pid = ProcessInfo.processInfo.processIdentifier
            let script = """
            #!/bin/bash
            exec >> "$HOME/Library/Logs/ClaudeBar.log" 2>&1
            echo "swap: waiting for pid \(pid)"
            while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.3; done
            /bin/sleep 1
            /bin/rm -rf "\(dest).new"
            if /usr/bin/ditto "\(staging)" "\(dest).new"; then
                /bin/rm -rf "\(dest)"
                /bin/mv "\(dest).new" "\(dest)"
                echo "swap: installed \(update.version) at \(dest)"
            else
                echo "swap: copy failed, keeping current app"
            fi
            /bin/rm -rf "\(staging)" "\(dmgPath)" "\(dest).new"
            /usr/bin/xattr -dr com.apple.quarantine "\(dest)" 2>/dev/null
            /usr/bin/open "\(dest)" || { /bin/sleep 2; /usr/bin/open "\(dest)"; }
            echo "swap: done"
            """
            let scriptPath = "/tmp/claudebar-swap.sh"
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try runTool("/bin/chmod", ["+x", scriptPath])

            let swapper = Process()
            swapper.executableURL = URL(fileURLWithPath: "/bin/bash")
            swapper.arguments = [scriptPath]
            try swapper.run()  // detached on purpose — it waits for us to exit

            AppLog.write("update: swapping to \(update.version), quitting")
            NSApp.terminate(nil)
        } catch {
            state = .failed(tr("Update failed — download it from GitHub",
                               "Cập nhật lỗi — tải thủ công trên GitHub"))
            AppLog.write("update failed: \(error.localizedDescription)")
        }
    }

    private func runTool(_ tool: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UsageError.message("\(tool) exited \(process.terminationStatus)")
        }
    }
}
