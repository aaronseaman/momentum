import SwiftUI
import MomentumKit

/// Three screens, two questions. Then Momentum takes over.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step = 0
    @State private var interests: [String] = ["productivity", "adhd"]

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Group {
                switch step {
                case 0: welcome
                case 1: interestsStep
                default: notificationsStep
                }
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 28)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            .id(step)
            Spacer(minLength: 24)
            HStack(spacing: 8) {
                ForEach(0..<3) { index in
                    Capsule()
                        .fill(index == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: index == step ? 22 : 8, height: 8)
                }
            }
            .padding(.bottom, 32)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.pageBackground)
        .animation(.snappy, value: step)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "bolt.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.accentColor)
            Text("Momentum")
                .font(.system(size: 44, weight: .bold, design: .rounded))
            Text("Your external executive function.")
                .font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 12) {
                Label("Watches your repos, builds, App Store and income.", systemImage: "eye")
                Label("Researches app ideas in the background.", systemImage: "dot.radiowaves.left.and.right")
                Label("Shows one next step. Asks one simple question.", systemImage: "1.circle")
                Label("No forms. No guilt. Data stays on your device.", systemImage: "heart")
            }
            .font(.body)
            .foregroundStyle(.secondary)
            Button("Get started") { step = 1 }
                .buttonStyle(.primary)
                .padding(.top, 8)
        }
    }

    private var interestsStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("What kind of apps interest you?")
                .font(.title.weight(.bold))
            Text("Pick any. I'll look for opportunities there and learn from your answers.")
                .foregroundStyle(.secondary)
            InterestPicker(selection: $interests)
            Button("Continue") { step = 2 }
                .buttonStyle(.primary)
                .disabled(interests.isEmpty)
        }
    }

    private var notificationsStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "sun.horizon")
                .font(.system(size: 48))
                .foregroundStyle(Theme.attention)
            Text("Want a short morning brief?")
                .font(.title.weight(.bold))
            Text("One notification with yesterday's income, a rising trend, your next action and at most one question. You can answer right from the notification.")
                .foregroundStyle(.secondary)
            AnswerButtons(options: [AnswerOption("yes", "Yes, please"), AnswerOption("no", "Not now")], tint: .accentColor) { option in
                withAnimation(.easeInOut) {
                    model.finishOnboarding(interests: interests, wantsNotifications: option.id == "yes")
                }
            }
        }
    }
}
