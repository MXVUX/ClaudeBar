import SwiftUI

@main
struct ClaudeBarApp: App {
    @StateObject private var model = UsageModel()
    @StateObject private var agents = AgentMonitor()
    @StateObject private var tokens = TokenStats()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model, agents: agents, tokens: tokens)
        } label: {
            Text(model.menuTitle)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
        }
        .menuBarExtraStyle(.window)
    }
}
