import SwiftUI
import MomentumKit

struct TodayView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Page {
            header
            NoticesList()
            NextActionCard(action: model.nextAction)
            if let question = model.currentQuestion {
                QuestionCard(question: question)
                    .id(question.id)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            } else {
                AllCaughtUpCard()
            }
            HStack(alignment: .top, spacing: Theme.spacing) {
                RevenueSnapshotCard()
                TrendSnapshotCard()
            }
            .fixedSize(horizontal: false, vertical: true)
            FocusLauncherCard()
        }
        .animation(.snappy, value: model.currentQuestion?.id)
        .navigationTitle("Today")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { CommonToolbar(model: model) }
        .refreshable { await model.refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greeting)
                .font(.largeTitle.weight(.bold))
            HStack(spacing: 8) {
                Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()))
                if model.isSyncing {
                    ProgressView().controlSize(.mini)
                    Text("Checking your tools…")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Hello, night owl"
        }
    }
}

// MARK: - Next Action

struct NextActionCard: View {
    @Environment(AppModel.self) private var model
    let action: NextAction

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardLabel(text: "Next action", symbol: "arrow.right.circle", tint: .accentColor)
            VStack(alignment: .leading, spacing: 6) {
                Text(action.title)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if action.projectID == nil && action.stepID == nil {
                setupButton
            } else {
                Button {
                    model.startFocus(minutes: 15, action: action)
                } label: {
                    Label("Start 15-minute timer", systemImage: "timer")
                }
                .buttonStyle(.primary)
                .keyboardShortcut(.return, modifiers: .command)

                HStack(spacing: 10) {
                    Button("Done") { model.markDone(projectID: action.projectID, stepID: action.stepID) }
                        .buttonStyle(.soft(Theme.money))
                    Button("Not now") { withAnimation(.snappy) { model.skip(action) } }
                        .buttonStyle(.soft(.secondary))
                    Menu {
                        Button("Snooze 2 hours") { model.snooze(projectID: action.projectID, hours: 2) }
                        Button("Snooze until tomorrow") { model.snooze(projectID: action.projectID, hours: 18) }
                        if let id = action.projectID {
                            Button("I'm stuck — break it down") { model.imStuck(id) }
                            Button("Open project") {
                                model.tab = .projects
                                model.projectPath = [id]
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: 14, style: .continuous))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .frame(width: 64)
                    .accessibilityLabel("More options")
                }
            }
        }
        .card(tint: .accentColor)
    }

    private var subtitle: String {
        [action.projectName, "\(action.minutes) min", action.reason].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder private var setupButton: some View {
        if model.data.integration(.github).isConnected || !model.data.projects.isEmpty {
            Button {
                model.tab = .radar
            } label: {
                Label("Open the Radar", systemImage: "dot.radiowaves.left.and.right")
            }
            .buttonStyle(.primary)
        } else {
            #if os(macOS)
            SettingsLink {
                Label("Connect GitHub", systemImage: "link")
            }
            .buttonStyle(.primary)
            #else
            Button {
                model.showSettings = true
            } label: {
                Label("Connect GitHub", systemImage: "link")
            }
            .buttonStyle(.primary)
            #endif
        }
    }
}

// MARK: - Question

struct QuestionCard: View {
    @Environment(AppModel.self) private var model
    let question: Question

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                CardLabel(text: "One question", symbol: "questionmark.bubble", tint: Theme.attention)
                Spacer()
                if model.pendingQuestionCount > 1 {
                    Button("Answer \(model.pendingQuestionCount - 1) more") { model.showBatch = true }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderless)
                }
            }
            Text(question.prompt)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let detail = question.detail {
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            AnswerButtons(options: question.options) { option in
                model.answer(question.id, option.id)
            }
            if question.defaultOptionID != nil, let label = question.label(for: question.defaultOptionID) {
                Text("No rush. If you skip this, I'll assume “\(label)”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .card(tint: Theme.attention)
        .accessibilityElement(children: .contain)
    }
}

struct AllCaughtUpCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.seal")
                .font(.title2)
                .foregroundStyle(Theme.money)
            VStack(alignment: .leading, spacing: 2) {
                Text("No questions right now").font(.headline)
                Text(model.pendingQuestionCount > 0 ? "That's enough for today. The rest can wait." : "I'll handle the details.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.pendingQuestionCount > 0 {
                Button("Answer more") { model.showBatch = true }
                    .buttonStyle(.borderless)
            }
        }
        .card()
    }
}

// MARK: - Notices ("I assumed … Tap to change")

struct NoticesList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ForEach(model.data.visibleNotices.prefix(3)) { notice in
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon(notice.kind))
                    .foregroundStyle(tint(notice.kind))
                    .padding(.top, 2)
                Text(notice.text)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if notice.questionID != nil {
                    Button("Change") { model.changeAssumption(notice) }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.borderless)
                }
                Button {
                    withAnimation(.snappy) { model.dismiss(notice) }
                } label: {
                    Image(systemName: "xmark").font(.caption.weight(.bold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
            }
            .padding(14)
            .background(tint(notice.kind).opacity(0.08), in: .rect(cornerRadius: 16, style: .continuous))
            .transition(.opacity)
        }
    }

    private func icon(_ kind: NoticeKind) -> String {
        switch kind {
        case .assumption: "wand.and.stars"
        case .info: "info.circle"
        case .alert: "exclamationmark.circle"
        case .win: "sparkles"
        }
    }

    private func tint(_ kind: NoticeKind) -> Color {
        switch kind {
        case .assumption, .info: .secondary
        case .alert: Theme.attention
        case .win: Theme.money
        }
    }
}

// MARK: - Snapshots

struct RevenueSnapshotCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let money = model.money
        Button {
            model.tab = .money
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                CardLabel(text: "Money", symbol: "dollarsign.circle", tint: Theme.money)
                if money.hasData {
                    Text(MoneyFormat.currency(money.yesterday, code: model.currency))
                        .font(.title.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    Text("yesterday · MRR \(MoneyFormat.currency(money.mrr, code: model.currency, compact: true))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Sparkline(points: money.last30Days)
                        .frame(height: 36)
                } else {
                    Text("Connect App Store Connect, RevenueCat or Stripe to see income here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .card(tint: Theme.money)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(money.hasData ? "Revenue yesterday \(MoneyFormat.currency(money.yesterday, code: model.currency))" : "Money not connected")
    }
}

struct TrendSnapshotCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.tab = .radar
            if let id = model.topOpportunity?.id { model.radarPath = [id] }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                CardLabel(text: "Rising", symbol: "arrow.up.right", tint: Theme.trend)
                if let opp = model.topOpportunity {
                    Text(opp.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(opp.opportunityScore ?? 0)")
                            .font(.title.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.trend)
                        Text("score").font(.caption).foregroundStyle(.secondary)
                    }
                    if let growth = opp.trend?.growthPercent {
                        Text("\(MoneyFormat.percent(growth)) mentions this week")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Researching opportunities in the background…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .card(tint: Theme.trend)
        }
        .buttonStyle(.plain)
    }
}

struct FocusLauncherCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let streak = ReviewBuilder.momentumDays(model.data, now: Date())
        HStack(spacing: 14) {
            Button {
                model.startFocus()
            } label: {
                Label("Focus session", systemImage: "headphones")
            }
            .buttonStyle(.soft(.accentColor))
            Button {
                model.isOverwhelmed = true
            } label: {
                Label("I'm overwhelmed", systemImage: "leaf")
            }
            .buttonStyle(.soft(.secondary))
        }
        if streak > 0 {
            Text("You made progress on \(streak) of the last 14 days.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }
}
