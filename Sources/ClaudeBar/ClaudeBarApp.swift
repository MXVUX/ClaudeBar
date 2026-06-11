import SwiftUI

@main
struct ClaudeBarApp: App {
    @StateObject private var model = UsageModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
        } label: {
            Text(model.menuTitle)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
        }
        .menuBarExtraStyle(.window)
    }
}
