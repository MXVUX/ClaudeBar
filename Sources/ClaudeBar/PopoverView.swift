import SwiftUI
import Charts
import ServiceManagement

struct PopoverView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var agents: AgentMonitor
    @ObservedObject var tokens: TokenStats
    @ObservedObject var updates: UpdateChecker
    @ObservedObject var status: StatusChecker
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
        // Closing the popover while in Settings shouldn't strand the next
        // open there — always come back to the main view.
        .onDisappear { showingSettings = false }
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

        if status.hasIssue {
            statusBanner
        }

        if model.availableSources.count > 1 {
            Picker("", selection: $model.selectedSource) {
                ForEach(model.availableSources) { source in
                    Text(model.sourceLabel(source)).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
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

        // No data yet (first fetch or just-switched tab) — say so instead of
        // showing a confusing half-empty popover.
        if model.usage == nil && model.errorMessage == nil {
            CardBox {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(tr("Loading usage data — up to a minute on first load…",
                            "Đang tải dữ liệu — lần đầu có thể mất tới 1 phút…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        // Ordered by value: limits first, cost second, agents, then the chart.
        if let usage = model.usage {
            if usage.hasAnyDisplayable {
                CollapsibleSection(tr("Limits", "Giới hạn"), key: "limits",
                                   summary: limitsSummary(usage)) {
                    CardBox { limitsRows(usage) }
                }
            } else {
                CardBox {
                    Label(tr("This plan has no usage limits to display.",
                             "Gói này không có limit nào để hiển thị."),
                          systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        if let today = tokens.today {
            CollapsibleSection(tr("Today · Claude Code", "Hôm nay · Claude Code"), key: "today",
                               trailing: "≈ $\(String(format: "%.2f", today.cost))") {
                CardBox { todayRows(today) }
            }
        }
        if !agents.agents.isEmpty {
            let working = agents.agents.filter(\.isBusy).count
            CollapsibleSection(tr("Agents running (\(agents.agents.count))",
                                  "Agent đang chạy (\(agents.agents.count))"),
                               key: "agents",
                               summary: tr("\(working) working", "\(working) đang chạy")) {
                CardBox { agentRows }
            }
        }
        if let usage = model.usage, usage.hasAnyDisplayable {
            sparklineSection
        }

        Divider()
        footer
    }

    private var statusBanner: some View {
        Link(destination: StatusChecker.pageURL) {
            Label("\(tr("Anthropic incident:", "Anthropic đang sự cố:")) \(status.summary)",
                  systemImage: "exclamationmark.icloud.fill")
                .font(.callout)
                .foregroundStyle(status.indicator == "minor" ? Color.orange : Color.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill((status.indicator == "minor" ? Color.orange : Color.red).opacity(0.12)))
    }

    private func limitsSummary(_ usage: UsageResponse) -> String {
        if usage.isSpendBased, let extra = usage.extraUsage, let limit = extra.monthlyLimit {
            return "$\(UsageModel.compactDollars(extra.usedCredits ?? 0))/$\(UsageModel.compactDollars(limit))"
        }
        return "\(UsageModel.percentText(usage.fiveHour?.utilization)) · \(UsageModel.percentText(usage.sevenDay?.utilization))"
    }

    private func updateBanner(_ update: AvailableUpdate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label(tr("ClaudePulse \(update.version) available", "Có bản mới \(update.version)"),
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

    @ViewBuilder
    private func limitsRows(_ usage: UsageResponse) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if usage.fiveHour?.utilization != nil {
                UsageRow(title: tr("Current session", "Session hiện tại"),
                         bucket: usage.fiveHour, resetStyle: .relative)
                if let forecast = model.sessionForecast {
                    Label(forecast.text, systemImage: forecast.isWarning
                          ? "flame.fill" : "gauge.with.dots.needle.33percent")
                        .font(.caption)
                        .foregroundStyle(forecast.isWarning ? Color.orange : Color.secondary)
                        .padding(.top, -6)
                }
            }
            if usage.sevenDay?.utilization != nil {
                UsageRow(title: tr("Weekly · All models", "Tuần · mọi model"),
                         bucket: usage.sevenDay, resetStyle: .absolute)
            }
            if let sonnet = usage.sevenDaySonnet, sonnet.utilization != nil {
                UsageRow(title: tr("Weekly · Sonnet", "Tuần · Sonnet"),
                         bucket: sonnet, resetStyle: .absolute)
            }
            if let opus = usage.sevenDayOpus, opus.utilization != nil {
                UsageRow(title: tr("Weekly · Opus", "Tuần · Opus"),
                         bucket: opus, resetStyle: .absolute)
            }
            if let extra = usage.extraUsage, extra.isEnabled == true {
                extraUsageRow(extra, primary: usage.isSpendBased)
            }
            if let design = usage.omelettePromotional, design.utilization != nil {
                UsageRow(title: "Claude Design", bucket: design, resetStyle: .absolute)
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
        if points.count >= 3, points.contains(where: { $0.s != nil || $0.w != nil }) {
            CollapsibleSection(tr("Last 24h", "24h qua"), key: "chart24h") {
                CardBox {
                HStack(spacing: 10) {
                    LegendDot(color: .green, label: "Session")
                    LegendDot(color: .blue, label: tr("Weekly", "Tuần"))
                    Spacer()
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
    }

    @ViewBuilder
    private var agentRows: some View {
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

    @ViewBuilder
    private func todayRows(_ today: DayUsage) -> some View {
            HStack {
                Text("in \(compactTokens(today.input)) · out \(compactTokens(today.output)) · cache \(compactTokens(today.cacheRead + today.cacheWrite))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(compactTokens(today.total))
                    .font(.callout.monospacedDigit().weight(.semibold))
            }
            if !today.models.isEmpty {
                Divider()
                // Per-model breakdown — names come straight from transcript
                // model ids, so brand-new models appear automatically.
                ForEach(today.models.values.sorted { $0.cost > $1.cost }) { share in
                    HStack {
                        Text(share.name).font(.caption)
                        Spacer()
                        Text("\(compactTokens(share.tokens)) tok · $\(share.cost, specifier: "%.2f")")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if tokens.days.count >= 2 {
                Divider()
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

    private func extraUsageRow(_ extra: ExtraUsage, primary: Bool) -> some View {
        // Amounts arrive in cents (8000 = $80.00).
        let used = extra.usedCredits ?? 0
        let limit = extra.monthlyLimit ?? 0
        let fraction = limit > 0 ? used / limit : (extra.utilization ?? 0) / 100
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(primary ? tr("Spend limit", "Hạn mức chi tiêu") : "Extra usage credits")
                    .font(.callout.weight(.medium))
                Spacer()
                Text("$\(UsageModel.compactDollars(used)) / $\(UsageModel.compactDollars(limit))")
                    .font(.callout.monospacedDigit())
            }
            ProgressView(value: min(fraction, 1))
                .tint(primary ? (fraction >= 0.9 ? .red : .green) : .purple)
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
                Task { await model.refresh(force: true) }
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
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var intervalSelection: Double = 60
    @State private var pendingFlow: ClaudeAuth.PendingFlow?
    @State private var pastedCode = ""
    @State private var authBusy = false
    @State private var authError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(tr("Account", "Tài khoản"))
            CardBox { accountContent }

            SectionHeader(tr("Appearance", "Giao diện"))
            CardBox {
                Text(tr("Theme", "Màu nền")).font(.callout)
                Picker("", selection: $themeManager.theme) {
                    Text(tr("System", "Hệ thống")).tag(AppTheme.system)
                    Text(tr("Light", "Sáng")).tag(AppTheme.light)
                    Text(tr("Dark", "Tối")).tag(AppTheme.dark)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Divider()
                Text(tr("Language", "Ngôn ngữ")).font(.callout)
                Picker("", selection: $l10n.language) {
                    Text("English").tag(AppLanguage.en)
                    Text("Tiếng Việt").tag(AppLanguage.vi)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            SectionHeader("Menu bar")
            CardBox {
                Toggle("Session %", isOn: $model.showSession)
                Toggle(tr("Weekly %", "Tuần %"), isOn: $model.showWeekly)
                Toggle(tr("Countdown to session reset", "Đếm ngược tới reset session"),
                       isOn: $model.showCountdown)
            }
            .font(.callout)
            .toggleStyle(.checkbox)

            SectionHeader(tr("Refresh interval", "Tần suất refresh"))
            CardBox {
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

            SectionHeader(tr("General", "Chung"))
            CardBox {
                Toggle(tr("Launch at login", "Khởi động cùng hệ thống"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            UserDefaults.standard.set(enabled, forKey: "launchAtLoginOn")
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Toggle(tr("Check for updates automatically", "Tự động kiểm tra bản cập nhật"),
                       isOn: $updates.autoCheck)
                Divider()
                HStack(spacing: 8) {
                    Button(tr("Check for updates", "Kiểm tra cập nhật")) {
                        Task { await updates.check(silent: false) }
                    }
                    .font(.caption)
                    if updates.state == .checking || updates.state == .downloading {
                        ProgressView().controlSize(.small)
                    } else if let update = updates.available {
                        Text("→ \(update.version)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.blue)
                        Button(tr("Update now", "Cập nhật ngay")) {
                            Task { await updates.updateNow() }
                        }
                        .font(.caption)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else if case .failed(let message) = updates.state {
                        Text(message).font(.caption).foregroundStyle(.red)
                    } else if updates.lastChecked != nil {
                        Text(tr("Up to date", "Đang là bản mới nhất"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            .font(.callout)
            .toggleStyle(.checkbox)

            HStack(spacing: 10) {
                Link(destination: URL(string: "https://github.com/MXVUX/ClaudePulse")!) {
                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: URL(string: "https://github.com/MXVUX/ClaudePulse/issues/new")!) {
                    Label(tr("Report a bug", "Báo lỗi"), systemImage: "ladybug")
                }
                Spacer()
                Text("v\(UpdateChecker.currentVersion)")
                    .foregroundStyle(.tertiary)
                Button(tr("Quit", "Thoát")) { NSApp.terminate(nil) }
            }
            .font(.caption)
            .padding(.top, 2)
        }
        .onAppear { intervalSelection = model.refreshInterval }
    }

    @ViewBuilder
    private var accountContent: some View {
        Group {
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
                        model.selectedSource = .claudeCode
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
                Text(tr("Connect ClaudePulse directly to your Claude account — it keeps its own sign-in, independent of Claude Code.",
                        "Kết nối ClaudePulse trực tiếp với tài khoản Claude — app tự quản lý đăng nhập riêng, độc lập với Claude Code."))
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
                model.selectedSource = .ownLogin
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

/// Section with a tappable header that collapses/expands its content; the
/// choice is remembered per section. Collapsed headers can show a summary.
struct CollapsibleSection<Content: View>: View {
    private let title: String
    private let summary: String?
    private let trailing: String?
    private let storageKey: String
    private let content: Content
    @State private var expanded: Bool

    init(_ title: String, key: String, summary: String? = nil, trailing: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.summary = summary
        self.trailing = trailing
        self.storageKey = "expand.\(key)"
        self.content = content()
        _expanded = State(initialValue:
            UserDefaults.standard.object(forKey: "expand.\(key)") as? Bool ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                UserDefaults.standard.set(expanded, forKey: storageKey)
            } label: {
                HStack(spacing: 6) {
                    SectionHeader(title)
                    if !expanded, let summary {
                        Text(summary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if let trailing {
                        Text(trailing)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded { content }
        }
    }
}

/// Rounded grouped box, System Settings style — section header sits outside.
struct CardBox<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
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
