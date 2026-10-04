import SwiftUI
import MomentumKit

/// Full-window focus session with a calm timer and a quiet "co-working" companion.
struct FocusView: View {
    @Environment(AppModel.self) private var model
    let run: FocusRun
    @State private var confirmEnd = false

    private static let companion = [
        "I'm right here with you.",
        "One thing at a time.",
        "Messy progress is still progress.",
        "If your mind wanders, just come back. No harm done.",
        "You started. That's the hard part.",
        "Breathe out. Keep going."
    ]

    var body: some View {
        TimelineView(.periodic(from: run.startedAt, by: 1)) { timeline in
            let remaining = max(0, run.endsAt.timeIntervalSince(timeline.date))
            let progress = 1 - remaining / TimeInterval(run.minutes * 60)
            VStack(spacing: 28) {
                Spacer()
                Text(run.title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                ZStack {
                    ProgressRing(progress: progress, tint: .accentColor, lineWidth: 14)
                        .frame(width: 240, height: 240)
                    VStack(spacing: 6) {
                        Text(timeString(remaining))
                            .font(.system(size: 56, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText(countsDown: true))
                        Text(remaining > 0 ? "remaining" : "done!")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(Int(remaining / 60)) minutes remaining")

                Text(companionLine(at: timeline.date))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
                    .id(companionLine(at: timeline.date))
                    .animation(.easeInOut(duration: 0.8), value: companionLine(at: timeline.date))

                Spacer()
                VStack(spacing: 12) {
                    if remaining <= 0 {
                        Button("Finish") { model.endFocus(completed: true) }
                            .buttonStyle(.primary(Theme.money))
                    } else {
                        Button("I'm done early") { model.endFocus(completed: true) }
                            .buttonStyle(.primary)
                    }
                    Button("Stop for now") { confirmEnd = true }
                        .buttonStyle(.soft(.secondary))
                }
                .frame(maxWidth: 420)
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: remaining <= 0) { _, finished in
                if finished { model.endFocus(completed: true) }
            }
        }
        .background(.regularMaterial)
        .background(Theme.pageBackground)
        .ignoresSafeArea()
        .confirmationDialog("Stop this session?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("Stop — it still counts") { model.endFocus(completed: false) }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("Every minute you spent counts.")
        }
        #if os(macOS)
        .onExitCommand { confirmEnd = true }
        #endif
    }

    private func timeString(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func companionLine(at date: Date) -> String {
        let elapsed = Int(date.timeIntervalSince(run.startedAt) / 60)
        if elapsed < 1 { return "Settling in. I'm here too." }
        if run.minutes >= 10, elapsed == run.minutes / 2 { return "Halfway there." }
        return Self.companion[(elapsed / 4) % Self.companion.count]
    }
}

/// "Did you finish it?" — one direct question after each session.
struct FocusFinishedSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let run: FocusRun

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "sparkles")
                .font(.system(size: 44))
                .foregroundStyle(.yellow)
                .padding(.top, 24)
            Text("Nice work.")
                .font(.title.weight(.bold))
            if run.stepID != nil {
                Text("Did you finish “\(run.title)”?")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                AnswerButtons(options: [AnswerOption("done", "Done"), AnswerOption("notyet", "Not yet"), AnswerOption("blocked", "Blocked")],
                              tint: .accentColor) { option in
                    model.finishStep(run, outcome: option.id)
                    dismiss()
                }
            } else {
                Text("That counts. Want to keep the momentum?")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                Button("Back to Today") {
                    model.focusFinished = nil
                    dismiss()
                }
                .buttonStyle(.primary)
            }
        }
        .padding(24)
        .frame(maxWidth: 480)
        #if os(iOS)
        .presentationDetents([.medium])
        #endif
    }
}

/// One tap hides everything but a single tiny step.
struct OverwhelmView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let action = model.nextAction
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "leaf")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.money)
            Text("Take a breath.")
                .font(.largeTitle.weight(.semibold))
            VStack(spacing: 8) {
                Text("Your next tiny step is:")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(action.tinyStep)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            Button {
                model.startTinyStep()
            } label: {
                Label("Start 5-minute timer", systemImage: "timer")
            }
            .buttonStyle(.primary(Theme.money))
            .frame(maxWidth: 360)
            Spacer()
            Button("I'm okay now") { model.isOverwhelmed = false }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .padding(.bottom, 32)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.pageBackground)
        .ignoresSafeArea()
        #if os(macOS)
        .onExitCommand { model.isOverwhelmed = false }
        #endif
        .accessibilityAddTraits(.isModal)
    }
}

/// Answer several questions in a row — five in twenty seconds.
struct BatchQuestionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Page {
                let questions = model.data.pendingQuestions.filter { $0.expiresAt > Date() }
                if questions.isEmpty {
                    EmptyState(symbol: "checkmark.seal", title: "All answered", message: "I'll take it from here.")
                } else {
                    ForEach(questions) { question in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(question.prompt)
                                .font(.headline)
                                .fixedSize(horizontal: false, vertical: true)
                            if let detail = question.detail {
                                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                            }
                            AnswerButtons(options: question.options) { option in
                                withAnimation(.snappy) { model.answer(question.id, option.id) }
                            }
                        }
                        .card()
                        .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity)))
                    }
                }
            }
            .navigationTitle("Quick answers")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 520)
        #endif
    }
}
