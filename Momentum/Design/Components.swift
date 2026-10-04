import SwiftUI
import Charts
import MomentumKit

/// Small uppercase label above a card's content.
struct CardLabel: View {
    let text: String
    var symbol: String?
    var tint: Color = .secondary

    var body: some View {
        Label {
            Text(text.uppercased())
        } icon: {
            if let symbol { Image(systemName: symbol) }
        }
        .font(.caption.weight(.semibold))
        .tracking(0.6)
        .foregroundStyle(tint)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Up to four answer buttons in a grid that never feels cramped.
struct AnswerButtons: View {
    let options: [AnswerOption]
    var tint: Color = Theme.attention
    let onAnswer: (AnswerOption) -> Void

    var body: some View {
        let columnCount = options.count == 1 ? 1 : 2
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columnCount), spacing: 10) {
            ForEach(options) { option in
                Button(option.label) { onAnswer(option) }
                    .buttonStyle(.soft(tint))
                    .accessibilityHint("Answers the question")
            }
        }
    }
}

struct ProgressRing: View {
    let progress: Double
    var tint: Color = .accentColor
    var lineWidth: CGFloat = 6

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth, value: progress)
        }
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(progress * 100)) percent")
    }
}

struct StageBadge: View {
    let stage: ProjectStage

    var body: some View {
        Text(stage.title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(Theme.color(for: stage))
            .background(Theme.color(for: stage).opacity(0.12), in: .capsule)
            .accessibilityLabel("Stage: \(stage.title)")
    }
}

/// A tiny, axis-free trend line.
struct Sparkline: View {
    let points: [DailyPoint]
    var tint: Color = Theme.money

    var body: some View {
        Chart(points) { point in
            AreaMark(x: .value("Day", point.day.rawValue), y: .value("Amount", point.amount))
                .foregroundStyle(LinearGradient(colors: [tint.opacity(0.25), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.catmullRom)
            LineMark(x: .value("Day", point.day.rawValue), y: .value("Amount", point.amount))
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .interpolationMethod(.catmullRom)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .accessibilityHidden(true)
    }
}

struct ScorePill: View {
    let label: String
    let value: String
    var tint: Color = .secondary

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.bold)).monospacedDigit().foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(tint.opacity(0.08), in: .rect(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(message).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.soft).frame(maxWidth: 280).padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .card()
    }
}

/// Page scaffold: calm background, readable column, generous spacing.
struct Page<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                content
            }
            .padding(Theme.pagePadding)
            .readableColumn()
        }
        .background(Theme.pageBackground)
    }
}

/// Toolbar items shared by every tab.
struct CommonToolbar: ToolbarContent {
    let model: AppModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.isOverwhelmed = true
            } label: {
                Label("I'm overwhelmed", systemImage: "leaf")
            }
            .help("Hide everything except one tiny step")
        }
        #if os(iOS)
        ToolbarItem(placement: .topBarLeading) {
            Button {
                model.showSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
        #endif
    }
}
