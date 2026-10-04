import SwiftUI
import MomentumKit

struct RadarView: View {
    @Environment(AppModel.self) private var model
    @State private var keyword = ""
    @State private var showDismissed = false

    var body: some View {
        let opportunities = model.data.opportunities
            .filter { showDismissed ? $0.status == .dismissed : $0.isVisible }
            .sorted { ($0.opportunityScore ?? -1, $0.createdAt) > ($1.opportunityScore ?? -1, $1.createdAt) }
        Page {
            Text("Momentum watches App Store search, Reddit and Hacker News, then scores each idea for momentum, competition, difficulty and fit.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Research a keyword (optional)", text: $keyword)
                    .textFieldStyle(.plain)
                    .onSubmit(submit)
                    .submitLabel(.search)
                if !keyword.isEmpty {
                    Button("Research", action: submit).buttonStyle(.borderless)
                }
            }
            .padding(14)
            .background(Theme.cardBackground, in: .rect(cornerRadius: 14, style: .continuous))

            if let top = opportunities.first(where: { $0.opportunityScore != nil }), !showDismissed {
                RecommendedCard(opportunity: top)
            }

            if opportunities.isEmpty {
                EmptyState(symbol: "dot.radiowaves.left.and.right",
                           title: showDismissed ? "Nothing dismissed" : "Warming up",
                           message: showDismissed ? "Ideas you dismiss land here." : "I'm gathering your first opportunities. Pull to refresh, or type a keyword above.")
            } else {
                ForEach(opportunities) { opp in
                    NavigationLink(value: opp.id) {
                        OpportunityRow(opportunity: opp)
                    }
                    .buttonStyle(.plain)
                }
            }

            Toggle("Show dismissed ideas", isOn: $showDismissed)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
        .navigationTitle("Radar")
        .navigationDestination(for: UUID.self) { id in
            OpportunityDetailView(id: id)
        }
        .toolbar { CommonToolbar(model: model) }
        .refreshable { await model.refresh() }
    }

    private func submit() {
        let text = keyword
        keyword = ""
        model.research(keyword: text)
    }
}

struct RecommendedCard: View {
    @Environment(AppModel.self) private var model
    let opportunity: Opportunity

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardLabel(text: "Recommended", symbol: "star", tint: Theme.trend)
            Text(opportunity.title).font(.title2.weight(.semibold))
            if let summary = opportunity.displaySummary {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            HStack(spacing: 10) {
                Button("See why") { model.radarPath = [opportunity.id] }
                    .buttonStyle(.soft(Theme.trend))
                Button("Make it a project") { model.promote(opportunity.id) }
                    .buttonStyle(.soft(Theme.money))
            }
        }
        .card(tint: Theme.trend)
    }
}

struct OpportunityRow: View {
    let opportunity: Opportunity

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                ProgressRing(progress: Double(opportunity.opportunityScore ?? 0) / 100, tint: Theme.trend, lineWidth: 5)
                if let score = opportunity.opportunityScore {
                    Text("\(score)").font(.headline).monospacedDigit()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(opportunity.title).font(.headline)
                    if opportunity.status == .starred {
                        Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                    }
                }
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .card()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(opportunity.title), opportunity score \(opportunity.opportunityScore.map(String.init) ?? "pending")")
    }

    private var caption: String {
        guard opportunity.researchedAt != nil else { return "Waiting for research" }
        var parts: [String] = []
        if let growth = opportunity.trend?.growthPercent { parts.append("Trend \(MoneyFormat.percent(growth))") }
        if let c = opportunity.competition?.score { parts.append("Competition \(c)/10") }
        if let d = opportunity.difficulty { parts.append("\(d.hoursLow)–\(d.hoursHigh)h") }
        return parts.joined(separator: " · ")
    }
}
