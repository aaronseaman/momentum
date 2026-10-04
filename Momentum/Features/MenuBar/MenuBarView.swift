#if os(macOS)
import SwiftUI
import AppKit
import MomentumKit

/// Glanceable command center in the menu bar: next action, one question, money.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let action = model.nextAction
        let money = model.money
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                CardLabel(text: "Next action", symbol: "arrow.right.circle", tint: .accentColor)
                Text(action.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                Button("Start 15-minute timer") {
                    NSApp.activate()
                    model.startFocus(minutes: 15, action: action)
                }
                .buttonStyle(.primary)
                .disabled(action.stepID == nil)
            }

            if let question = model.currentQuestion {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    CardLabel(text: "One question", symbol: "questionmark.bubble", tint: Theme.attention)
                    Text(question.prompt).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    AnswerButtons(options: question.options) { model.answer(question.id, $0.id) }
                }
            }

            if money.hasData {
                Divider()
                HStack {
                    VStack(alignment: .leading) {
                        Text("Yesterday").font(.caption).foregroundStyle(.secondary)
                        Text(MoneyFormat.currency(money.yesterday, code: model.currency)).font(.title3.weight(.bold)).foregroundStyle(Theme.money)
                    }
                    Spacer()
                    Sparkline(points: money.last30Days).frame(width: 120, height: 32)
                }
            }

            Divider()
            HStack {
                Button("Open Momentum") {
                    NSApp.activate()
                    if NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) == nil {
                        openWindow(id: "main")
                    }
                }
                Spacer()
                Button("I'm overwhelmed") {
                    NSApp.activate()
                    model.isOverwhelmed = true
                }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(16)
        .frame(width: 340)
        .fontDesign(.rounded)
    }
}
#endif
