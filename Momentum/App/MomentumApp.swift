import SwiftUI
import MomentumKit

@main
struct MomentumApp: App {
    @State private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(model)
                .onAppear { model.start() }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active: model.becameActive()
                    case .background: model.enteredBackground()
                    default: break
                    }
                }
        }
        #if os(iOS)
        .backgroundTask(.appRefresh(AppModel.refreshTaskID)) {
            await AppModel.shared.backgroundRefresh()
        }
        #endif
        #if os(macOS)
        .defaultSize(width: 1040, height: 760)
        #endif
        .commands {
            MomentumCommands(model: model)
        }

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(model)
                .frame(minWidth: 560, minHeight: 620)
        }

        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            Image(systemName: "bolt.circle")
                .accessibilityLabel("Momentum")
        }
        .menuBarExtraStyle(.window)
        #endif
    }
}

/// Keyboard shortcuts: ⌘1–5 for areas, ⇧⌘F focus, ⇧⌘O overwhelmed, ⌘R refresh.
struct MomentumCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Momentum") {
            ForEach(Array(AppTab.allCases.enumerated()), id: \.element) { index, tab in
                Button(tab.title) { model.tab = tab }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
            Divider()
            Button("Start Focus Session") { model.startFocus() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("I'm Overwhelmed") { model.isOverwhelmed = true }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Answer Questions") { model.showBatch = true }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Divider()
            Button("Refresh Now") { Task { await model.refresh() } }
                .keyboardShortcut("r", modifiers: .command)
        }
    }
}
