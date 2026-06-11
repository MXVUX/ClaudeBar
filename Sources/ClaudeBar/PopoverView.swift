import SwiftUI
import Charts
import ServiceManagement

struct PopoverView: View {
    @ObservedObject var model: UsageModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var intervalSelection: Double = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let error = model.errorMessage, model.usage == nil {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            if let u = model.usage {
                UsageRow(
                    title: "Current session",
                    bucket: u.fiveHour,
                    resetStyle: .relative
                )
                if let forecast = model.sessionForecast {
                    Label(forecast.text, systemImage: forecast.isWarning ? "flame.fill" : "gauge.with.dots.needle.33percent")
                        .font(.caption)
                        .foregroundStyle(forecast.isWarning ? Color.orange : Color.secondary)
                        .padding(.top, -8)
                }
                UsageRow(
                    title: "Weekly · All models",
                    bucket: u.sevenDay,
                    resetStyle: .absolute
                )
                if let sonnet = u.sevenDaySonnet, sonnet.utilization != nil {
                    UsageRow(title: "Weekly · Sonnet", bucket: sonnet, resetStyle: .absolute)
                }
                if let opus = u.sevenDayOpus, opus.utilization != nil {
                    UsageRow(title: "Weekly · Opus", bucket: opus, resetStyle: .absolute)
                }
                if let extra = u.extraUsage, extra.isEnabled == true {
                    extraUsageRow(extra)
                }
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
                sparkline
            }

            Divider()
            displayOptions
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 300)
        .onAppear {
            intervalSelection = model.refreshInterval
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private var header: some View {
        HStack {
            Text("Claude Usage")
                .font(.headline)
            Spacer()
            if let plan = model.subscriptionType {
                Text(plan.capitalized)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
            }
        }
    }

    @ViewBuilder
    private var sparkline: some View {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        let points = model.samples.filter { $0.t >= cutoff }
        if points.count >= 3 {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text("24h").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Label("Session", systemImage: "circle.fill")
                        .font(.caption2).foregroundStyle(.green)
                    Label("Weekly", systemImage: "circle.fill")
                        .font(.caption2).foregroundStyle(.blue)
                    Spacer()
                }
                Chart(points) { sample in
                    if let v = sample.s {
                        LineMark(x: .value("Time", sample.t),
                                 y: .value("Pct", v),
                                 series: .value("Series", "Session"))
                            .foregroundStyle(.green)
                            .interpolationMethod(.monotone)
                    }
                    if let v = sample.w {
                        LineMark(x: .value("Time", sample.t),
                                 y: .value("Pct", v),
                                 series: .value("Series", "Weekly"))
                            .foregroundStyle(.blue)
                            .interpolationMethod(.monotone)
                    }
                }
                .chartYScale(domain: 0...100)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: 6)) {
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour(), centered: false)
                            .font(.caption2)
                    }
                }
                .chartYAxis {
                    AxisMarks(values: [0, 50, 100]) {
                        AxisGridLine()
                        AxisValueLabel().font(.caption2)
                    }
                }
                .frame(height: 64)
            }
        }
    }

    private var displayOptions: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Session %", isOn: $model.showSession)
                Toggle("Weekly %", isOn: $model.showWeekly)
                Toggle("Countdown tới reset session", isOn: $model.showCountdown)
            }
            .font(.caption)
            .toggleStyle(.checkbox)
            .padding(.top, 4)
        } label: {
            Text("Hiển thị trên menu bar")
                .font(.caption.weight(.medium))
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
        VStack(alignment: .leading, spacing: 10) {
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
                .help("Refresh ngay")
            }

            HStack {
                Text("Refresh").font(.caption)
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

            HStack {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .font(.caption)
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
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .font(.caption)
            }
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
            }
            ProgressView(value: min(value / 100, 1))
                .tint(barColor)
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
