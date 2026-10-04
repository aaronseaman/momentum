import Foundation
import AppIntents
import MomentumKit

/// "Hey Siri, what's my next action in Momentum?"
struct NextActionIntent: AppIntent {
    static let title: LocalizedStringResource = "What's my next action?"
    static let description: IntentDescription? = IntentDescription("Tells you the single most useful next step.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let action = AppModel.shared.nextAction
        return .result(dialog: "\(action.title). About \(action.minutes) minutes.")
    }
}

/// "How much did I make this month?"
struct RevenueIntent: AppIntent {
    static let title: LocalizedStringResource = "How much did I make?"
    static let description: IntentDescription? = IntentDescription("Answers money questions like “this month” or “yesterday”.")

    @Parameter(title: "Question", default: "How much did I make this month?")
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        guard model.money.hasData else {
            return .result(dialog: "Connect App Store Connect, RevenueCat or Stripe in Momentum first.")
        }
        let answer = MoneyQuery.answer(question, data: model.data, now: Date())
        return .result(dialog: "\(answer.text)")
    }
}

struct StartFocusIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a focus session"
    static let description: IntentDescription? = IntentDescription("Starts a focus timer on your next action.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.startFocus()
        return .result()
    }
}

struct OverwhelmedIntent: AppIntent {
    static let title: LocalizedStringResource = "I'm overwhelmed"
    static let description: IntentDescription? = IntentDescription("Hides everything except one tiny step.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.isOverwhelmed = true
        return .result()
    }
}

struct MomentumShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NextActionIntent(), phrases: [
            "What's my next action in \(.applicationName)",
            "What should I do next in \(.applicationName)"
        ], shortTitle: "Next action", systemImageName: "arrow.right.circle")
        AppShortcut(intent: RevenueIntent(), phrases: [
            "How much did I make in \(.applicationName)",
            "Ask \(.applicationName) about money"
        ], shortTitle: "Revenue", systemImageName: "dollarsign.circle")
        AppShortcut(intent: StartFocusIntent(), phrases: [
            "Start focus in \(.applicationName)",
            "Start a focus session with \(.applicationName)"
        ], shortTitle: "Focus", systemImageName: "timer")
        AppShortcut(intent: OverwhelmedIntent(), phrases: [
            "I'm overwhelmed in \(.applicationName)",
            "\(.applicationName) I'm overwhelmed"
        ], shortTitle: "Overwhelmed", systemImageName: "leaf")
    }
}
