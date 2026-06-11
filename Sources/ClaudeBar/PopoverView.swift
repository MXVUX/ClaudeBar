import SwiftUI
import Charts
import ServiceManagement

struct PopoverView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var agents: AgentMonitor
    @ObservedObject var tokens: TokenStats
    @ObservedObject var updates: UpdateChecker
    @ObservedObject private var l10n = L10n.shared
    @State private var showingSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if showingSettings {
                SettingsView(model: model, updates: updates)
            } else {
                mainContent
            }
        }
        .padding(16)
        .frame(width: 312)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(showingSettings ? tr("Settings", "Cài đặt") : "Claude Usage")
                .font(.headline)
            if !showingSettings, let plan = model.subscriptionType {
                Text(plan.capitalized)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
            }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showingSettings.toggle() }
            } label: {
                Image(systemName: showingSettings ? "chevron.left" : "gearshape")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(showingSettings ? tr("Back", "Quay lại") : tr("Settings", "Cài đặt"))
        }
    }

    // MARK: - Main

    @ViewBuilder
    private var mainContent: some View {
        if let update = updates.available {
            updateBanner(update)
        }

        if let error = model.errorMessage, model.usage == nil {
            VStack(alignment: .leading, spacing: 6) {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text(tr("Open Claude Code and run any prompt, then press ↻ — or use Sign in with Claude in Settings (⚙) if you rarely open Claude Code.",
                        "Mở Claude Code chạy một lệnh bất kỳ rồi bấm ↻ — hoặc dùng Sign in with Claude trong Cài đặt (⚙) nếu bạn ít mở Claude Code."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if let usage = model.usage {
            limitsSection(usage)
            sparklineSection
        }
        if !agents.agents.isEmpty {
            agentsSection
        }
        if let today = tokens.today {
            todaySection(today)
        }

        Divider()
        footer
    }

    private func updateBanner(_ update: AvailableUpdate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label(tr("ClaudeBar \(update.version) available", "Có bản mới \(update.version)"),
                      systemImage: "arrow.down.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.blue)
                Spacer()
                if updates.state == .downloading {
                    ProgressView().controlSize(.small)
                } else {
                    Button(tr("Update", "Cập nhật")) {
                        Task { await updates.updateNow() }
                    }
                    .font(.caption)
                    Link(destination: update.pageURL) {
                        Image(systemName: "info.circle")
                    }
                    .help(tr("Release notes", "Có gì mới"))
                }
            }
            if case .failed(let message) = updates.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.1)))
    }

    private func limitsSection(_ usage: UsageResponse) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(tr("Limits", "Giới hạn"))
            UsageRow(title: tr("Current session", "Session hiện tại"),
                     bucket: usage.fiveHour, resetStyle: .relative)
            if let forecast = model.sessionForecast {
                Label(forecast.text, systemImage: forecast.isWarning
                      ? "flame.fill" : "gauge.with.dots.needle.33percent")
                    .font(.caption)
                    .foregroundStyle(forecast.isWarning ? Color.orange : Color.secondary)
                    .padding(.top, -6)
            }
            UsageRow(title: tr("Weekly · All models", "Tuần · mọi model"),
                     bucket: usage.sevenDay, resetStyle: .absolute)
            if let sonnet = usage.sevenDaySonnet, sonnet.utilization != nil {
                UsageRow(title: tr("Weekly · Sonnet", "Tuần · Sonnet"),
                         bucket: sonnet, resetStyle: .absolute)
            }
            if let opus = usage.sevenDayOpus, opus.utilization != nil {
                UsageRow(title: tr("Weekly · Opus", "Tuần · Opus"),
                         bucket: opus, resetStyle: .absolute)
            }
            if let extra = usage.extraUsage, extra.isEnabled == true {
                extraUsageRow(extra)
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var sparklineSection: some View {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        let points = model.samples.filter { $0.t >= cutoff }
        if points.count >= 3 {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    SectionHeader(tr("Last 24h", "24h qua"))
                    Spacer()
                    LegendDot(color: .green, label: "Session")
                    LegendDot(color: .blue, label: tr("Weekly", "Tuần"))
                }
                Chart(points) { sample in
                    if let v = sample.s {
                        LineMark(x: .value("Time", sample.t), y: .value("Pct", v),
                                 series: .value("Series", "Session"))
                            .foregroundStyle(.green)
                            .interpolationMethod(.monotone)
                    }
                    if let v = sample.w {
                        LineMark(x: .value("Time", sample.t), y: .value("Pct", v),
                                 series: .value("Series", "Weekly"))
                            .foregroundStyle(.blue)
                            .interpolationMethod(.monotone)
                    }
                }
                .chartYScale(domain: 0...100)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: 6)) {
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour()).font(.caption2)
                    }
                }
                .chartYAxis {
                    AxisMarks(values: [0, 50, 100]) {
                        AxisGridLine()
                        AxisValueLabel().font(.caption2)
                    }
                }
                .frame(height: 60)
            }
        }
    }

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(tr("Agents running (\(agents.agents.count))",
                             "Agent đang chạy (\(agents.agents.count))"))
            ForEach(agents.agents) { agent in
                HStack(spacing: 8) {
                    Circle()
                        .fill(agent.isBusy ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 7, height: 7)
                    Text(agent.name)
                        .font(.callout.weight(.medium))
                    Text(agent.projectName)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(agent.isBusy ? tr("working", "đang chạy") : tr("idle", "chờ"))
                        .font(.caption)
                        .foregroundStyle(agent.isBusy ? Color.green : Color.secondary)
                }
                .help(agent.cwd)
            }
        }
    }

    private func todaySection(_ today: DayUsage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(tr("Today · Claude Code", "Hôm nay · Claude Code"))
                Spacer()
                Text("≈ $\(today.cost, specifier: "%.2f") \(tr("API value", "giá API"))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .help(tr("What today's usage would cost at API list prices — not a charge",
                             "Quy đổi theo giá niêm yết API để tham khảo — không phải tiền bị trừ"))
            }
            HStack(spacing: 12) {
                TokenStat(label: "in", value: today.input)
                TokenStat(label: "out", value: today.output)
                TokenStat(label: "cache", value: today.cacheRead + today.cacheWrite)
                Spacer()
                Text("\(compactTokens(today.total)) tok")
                    .font(.callout.monospacedDigit().weight(.semibold))
            }
            if tokens.days.count >= 2 {
                Chart(tokens.days) { day in
                    BarMark(x: .value("Day", day.day, unit: .day),
                            y: .value("Cost", day.cost))
                        .foregroundStyle(Color.accentColor.opacity(0.7))
                        .cornerRadius(2)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) {
                        AxisValueLabel(format: .dateTime.weekday(.narrow)).font(.caption2)
                    }
                }
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 2)) {
                        AxisGridLine()
                        AxisValueLabel().font(.caption2)
                    }
                }
                .frame(height: 44)
                Text("\(tr("7 days", "7 ngày")) ≈ $\(tokens.weekCost, specifier: "%.2f")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func extraUsageRow(_ extra: ExtraUsage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Extra usage credits").font(.callout.weight(.medium))
                Spacer()
                if let used = extra.usedCredits, let limit = extra.monthlyLimit {
                    Text("\(Int(used)) / \(Int(limit)) \(extra.currency ?? "")")
                        .font(.callout.monospacedDigit())
                }
            }
            ProgressView(value: min((extra.utilization ?? 0) / 100, 1))
                .tint(.purple)
        }
    }

    private var footer: some View {
        HStack {
            if let updated = model.lastUpdated {
                Text("\(tr("Updated", "Cập nhật")) \(updated.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(tr("Refresh now", "Refresh ngay"))
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var updates: UpdateChecker
    @ObservedObject private var l10n = L10n.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var intervalSelection: Double = 60
    @State private var pendingFlow: ClaudeAuth.PendingFlow?
    @State private var pastedCode = ""
    @State private var authBusy = false
    @State private var authError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            accountSection

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(tr("Language", "Ngôn ngữ"))
                Picker("", selection: $l10n.language) {
                    Text("English").tag(AppLanguage.en)
                    Text("Tiếng Việt").tag(AppLanguage.vi)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("Menu bar")
                Toggle("Session %", isOn: $model.showSession)
                Toggle(tr("Weekly %", "Tuần %"), isOn: $model.showWeekly)
                Toggle(tr("Countdown to session reset", "Đếm ngược tới reset session"),
                       isOn: $model.showCountdown)
            }
            .font(.callout)
            .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(tr("Refresh interval", "Tần suất refresh"))
                Picker("", selection: $intervalSelection) {
                    Text("1m").tag(60.0)
                    Text("2m").tag(120.0)
                    Text("5m").tag(300.0)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: intervalSelection) { _, newValue in
                    model.refreshInterval = newValue
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(tr("General", "Chung"))
                Toggle(tr("Launch at login", "Khởi động cùng hệ thống"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Toggle(tr("Check for updates automatically", "Tự động kiểm tra bản cập nhật"),
                       isOn: $updates.autoCheck)
            }
            .font(.callout)
            .toggleStyle(.checkbox)

            HStack(spacing: 8) {
                Button(tr("Check for updates", "Kiểm tra cập nhật")) {
                    Task { await updates.check(silent: false) }
                }
                .font(.caption)
                if updates.state == .checking {
                    ProgressView().controlSize(.small)
                } else if let update = updates.available {
                    Text("→ \(update.version)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                } else if case .failed(let message) = updates.state {
                    Text(message).font(.caption).foregroundStyle(.red)
                } else if updates.lastChecked != nil {
                    Text(tr("Up to date", "Đang là bản mới nhất"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()
            HStack(spacing: 10) {
                Link(destination: URL(string: "https://github.com/MXVUX/ClaudeBar")!) {
                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: URL(string: "https://github.com/MXVUX/ClaudeBar/issues/new")!) {
                    Label(tr("Report a bug", "Báo lỗi"), systemImage: "ladybug")
                }
                Spacer()
            }
            .font(.caption)

            HStack {
                Text("ClaudeBar \(UpdateChecker.currentVersion)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(tr("Quit", "Thoát")) { NSApp.terminate(nil) }
                    .font(.caption)
            }
        }
        .onAppear { intervalSelection = model.refreshInterval }
    }

    @ViewBuilder
    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(tr("Account", "Tài khoản"))
            if model.usingOwnLogin {
                HStack {
                    Label(tr("Signed in with Claude", "Đã đăng nhập với Claude"),
                          systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                    Spacer()
                    Button(tr("Sign out", "Đăng xuất")) {
                        ClaudeAuth.signOut()
                        model.usingOwnLogin = false
                        Task { await model.refresh() }
                    }
                    .font(.caption)
                }
                Text(tr("Connected directly to your Claude account.",
                        "Đang kết nối trực tiếp với tài khoản Claude của bạn."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let flow = pendingFlow {
                Text(tr("1. Approve in the browser   2. Copy the code   3. Paste it here:",
                        "1. Bấm đồng ý trong trình duyệt   2. Copy code   3. Dán vào đây:"))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                TextField(tr("Paste code…", "Dán code…"), text: $pastedCode)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                HStack {
                    Button(tr("Confirm", "Xác nhận")) { confirmSignIn(flow) }
                        .disabled(pastedCode.isEmpty || authBusy)
                    Button(tr("Cancel", "Huỷ")) {
                        pendingFlow = nil
                        pastedCode = ""
                        authError = nil
                    }
                    if authBusy { ProgressView().controlSize(.small) }
                }
                .font(.caption)
                if let authError {
                    Text(authError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Button {
                    let flow = ClaudeAuth.beginFlow()
                    pendingFlow = flow
                    NSWorkspace.shared.open(flow.url)
                } label: {
                    Label(tr("Sign in with Claude…", "Đăng nhập với Claude…"),
                          systemImage: "person.crop.circle.badge.checkmark")
                }
                Text(tr("Connect ClaudeBar directly to your Claude account — it keeps its own sign-in, independent of Claude Code.",
                        "Kết nối ClaudeBar trực tiếp với tài khoản Claude — app tự quản lý đăng nhập riêng, độc lập với Claude Code."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func confirmSignIn(_ flow: ClaudeAuth.PendingFlow) {
        authBusy = true
        authError = nil
        Task {
            do {
                let credentials = try await ClaudeAuth.exchange(pasted: pastedCode, flow: flow)
                ClaudeAuth.save(credentials)
                model.usingOwnLogin = true
                pendingFlow = nil
                pastedCode = ""
                AppLog.write("own login established")
                await model.refresh()
            } catch {
                authError = (error as? UsageError)?.text ?? error.localizedDescription
            }
            authBusy = false
        }
    }
}

// MARK: - Shared components

struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .kerning(0.6)
            .foregroundStyle(.tertiary)
    }
}

struct LegendDot: View {
    let color: Color
    let label: String
    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct TokenStat: View {
    let label: String
    let value: Int
    var body: some View {
        HStack(spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.tertiary)
            Text(compactTokens(value)).font(.caption.monospacedDigit())
        }
    }
}

enum ResetStyle { case relative, absolute }

struct UsageRow: View {
    let title: String
    let bucket: UsageBucket?
    let resetStyle: ResetStyle

    private var value: Double { bucket?.utilization ?? 0 }

    private var barColor: Color {
        switch value {
        case ..<70: return .green
        case ..<90: return .orange
        default: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout.weight(.medium))
                Spacer()
                Text(UsageModel.percentText(bucket?.utilization))
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(value >= 90 ? .red : .primary)
                    .contentTransition(.numericText())
                    .animation(.default, value: value)
            }
            ProgressView(value: min(value / 100, 1))
                .tint(barColor)
                .animation(.default, value: value)
            if let resets = bucket?.resetsAt {
                Text(resetText(resets))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func resetText(_ date: Date) -> String {
        switch resetStyle {
        case .relative:
            let seconds = max(0, date.timeIntervalSinceNow)
            let h = Int(seconds) / 3600
            let m = (Int(seconds) % 3600) / 60
            let duration = h > 0 ? "\(h)h \(m)m" : "\(m)m"
            return tr("Resets in \(duration)", "Reset sau \(duration)")
        case .absolute:
            var fmt = Date.FormatStyle()
                .weekday(.abbreviated).hour(.defaultDigits(amPM: .abbreviated)).minute()
            if L10n.shared.language == .vi {
                fmt = fmt.locale(Locale(identifier: "vi_VN"))
            }
            return tr("Resets \(date.formatted(fmt))", "Reset \(date.formatted(fmt))")
        }
    }
}
