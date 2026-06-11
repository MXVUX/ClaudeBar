import SwiftUI
import Charts
import ServiceManagement

struct PopoverView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var agents: AgentMonitor
    @ObservedObject var tokens: TokenStats
    @State private var showingSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if showingSettings {
                SettingsView(model: model)
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
            Text(showingSettings ? "Settings" : "Claude Usage")
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
            .help(showingSettings ? "Back" : "Settings")
        }
    }

    // MARK: - Main

    @ViewBuilder
    private var mainContent: some View {
        if let error = model.errorMessage, model.usage == nil {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
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

    private func limitsSection(_ usage: UsageResponse) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Limits")
            UsageRow(title: "Current session", bucket: usage.fiveHour, resetStyle: .relative)
            if let forecast = model.sessionForecast {
                Label(forecast.text, systemImage: forecast.isWarning
                      ? "flame.fill" : "gauge.with.dots.needle.33percent")
                    .font(.caption)
                    .foregroundStyle(forecast.isWarning ? Color.orange : Color.secondary)
                    .padding(.top, -6)
            }
            UsageRow(title: "Weekly · All models", bucket: usage.sevenDay, resetStyle: .absolute)
            if let sonnet = usage.sevenDaySonnet, sonnet.utilization != nil {
                UsageRow(title: "Weekly · Sonnet", bucket: sonnet, resetStyle: .absolute)
            }
            if let opus = usage.sevenDayOpus, opus.utilization != nil {
                UsageRow(title: "Weekly · Opus", bucket: opus, resetStyle: .absolute)
            }
            if let extra = usage.extraUsage, extra.isEnabled == true {
                extraUsageRow(extra)
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
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
                    SectionHeader("Last 24h")
                    Spacer()
                    LegendDot(color: .green, label: "Session")
                    LegendDot(color: .blue, label: "Weekly")
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
            SectionHeader("Agents running (\(agents.agents.count))")
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
                    Text(agent.isBusy ? "working" : "idle")
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
                SectionHeader("Today · Claude Code")
                Spacer()
                Text("≈ $\(today.cost, specifier: "%.2f") API value")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .help("What today's usage would cost at API list prices — not a charge")
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
                Text("7 days ≈ $\(tokens.weekCost, specifier: "%.2f")")
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
                Text("Updated \(updated.formatted(date: .omitted, time: .standard))")
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
            .help("Refresh now")
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var model: UsageModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var intervalSelection: Double = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("Menu bar")
                Toggle("Session %", isOn: $model.showSession)
                Toggle("Weekly %", isOn: $model.showWeekly)
                Toggle("Countdown to session reset", isOn: $model.showCountdown)
            }
            .font(.callout)
            .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("Refresh interval")
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
                SectionHeader("General")
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .font(.callout)
                    .toggleStyle(.checkbox)
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
            }

            Divider()
            HStack {
                Text("ClaudeBar \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .font(.caption)
            }
        }
        .onAppear { intervalSelection = model.refreshInterval }
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
            return h > 0 ? "Resets in \(h)h \(m)m" : "Resets in \(m)m"
        case .absolute:
            let fmt = Date.FormatStyle()
                .weekday(.abbreviated).hour(.defaultDigits(amPM: .abbreviated)).minute()
            return "Resets \(date.formatted(fmt))"
        }
    }
}
