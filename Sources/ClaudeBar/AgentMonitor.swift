import Foundation
import Darwin

struct AgentProcess: Identifiable {
    let pid: pid_t
    let name: String
    let cwd: String
    let startedAt: Date?
    let isBusy: Bool

    var id: pid_t { pid }
    var projectName: String {
        cwd.isEmpty ? "—" : (cwd as NSString).lastPathComponent
    }
}

/// Scans local processes for AI coding agents (Claude Code, Codex, Gemini CLI…)
/// using libproc — no extra permissions needed for same-user processes.
@MainActor
final class AgentMonitor: ObservableObject {
    @Published var agents: [AgentProcess] = []

    private var lastCPUTime: [pid_t: UInt64] = [:]
    private var timerTask: Task<Void, Never>?
    private static let watchedNames: Set<String> = ["claude", "codex", "gemini", "aider", "cursor-agent"]

    init() {
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.scan()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    private func scan() {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let byteCount = Int32(pids.count * MemoryLayout<pid_t>.size)
        let filled = proc_listallpids(&pids, byteCount)
        guard filled > 0 else { return }

        let myUID = getuid()
        var found: [AgentProcess] = []
        var nextCPUTime: [pid_t: UInt64] = [:]

        for pid in pids.prefix(Int(filled)) where pid > 0 {
            var pathBuf = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 else { continue }
            let name = (String(cString: pathBuf) as NSString).lastPathComponent
            guard Self.watchedNames.contains(name) else { continue }

            var bsdInfo = proc_bsdinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, bsdSize) == bsdSize,
                  bsdInfo.pbi_uid == myUID else { continue }
            let started = Date(timeIntervalSince1970: TimeInterval(bsdInfo.pbi_start_tvsec))

            var vnodeInfo = proc_vnodepathinfo()
            let vnodeSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            var cwd = ""
            if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnodeInfo, vnodeSize) == vnodeSize {
                cwd = withUnsafePointer(to: &vnodeInfo.pvi_cdir.vip_path) {
                    $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) }
                }
            }

            // Busy = meaningful CPU time consumed since the last 10s scan.
            var busy = false
            var usage = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: (rusage_info_t?).self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            if result == 0 {
                let total = usage.ri_user_time + usage.ri_system_time
                nextCPUTime[pid] = total
                if let previous = lastCPUTime[pid] {
                    busy = total &- previous > 150_000_000  // >150ms CPU in the window
                }
            }

            found.append(AgentProcess(pid: pid, name: name, cwd: cwd,
                                      startedAt: started, isBusy: busy))
        }

        lastCPUTime = nextCPUTime
        agents = found.sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }
}
