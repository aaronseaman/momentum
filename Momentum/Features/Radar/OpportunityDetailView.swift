import SwiftUI
import MomentumKit

struct OpportunityDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let id: UUID

    var body: some View {
        if let opp = model.data.opportunities.first(where: { $0.id == id }) {
            content(opp)
        } else {
            EmptyState(symbol: "questionmark", title: "Not found", message: "This idea was removed.")
                .padding()
        }
    }

    private func content(_ opp: Opportunity) -> some View {
        Page {
            VStack(alignment: .leading, spacing: 8) {
                Text(opp.title).font(.largeTitle.weight(.bold))
                if let summary = opp.displaySummary {
                    Text(summary).font(.body).foregroundStyle(.secondary)
                } else {
                    Label("Researching… this takes a moment.", systemImage: "hourglass").foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                ScorePill(label: "Opportunity", value: opp.opportunityScore.map(String.init) ?? "–", tint: Theme.trend)
                ScorePill(label: "Momentum", value: opp.momentumScore.map(String.init) ?? "–", tint: Theme.trend)
                ScorePill(label: "Competition", value: opp.competition.map { "\($0.score)/10" } ?? "–", tint: Theme.attention)
                ScorePill(label: "Difficulty", value: opp.difficulty.map { "\($0.score)/10" } ?? "–", tint: .secondary)
            }

            HStack(spacing: 10) {
                Button("Make it a project") { model.promote(opp.id) }
                    .buttonStyle(.primary(Theme.money))
                Button(opp.status == .starred ? "Starred" : "Star") {
                    model.setOpportunity(opp.id, status: opp.status == .starred ? .researched : .starred)
                }
                .buttonStyle(.soft(.yellow, selected: opp.status == .starred))
                .frame(maxWidth: 120)
                Button("Dismiss") { model.setOpportunity(opp.id, status: .dismissed) }
                    .buttonStyle(.soft(.secondary))
                    .frame(maxWidth: 120)
            }

            if let trend = opp.trend { trendCard(trend) }
            if let difficulty = opp.difficulty { difficultyCard(opp, difficulty) }
            if let competition = opp.competition { competitionCard(competition) }

            if !opp.relatedKeywords.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    CardLabel(text: "People also search", symbol: "text.magnifyingglass")
                    FlowChips(items: opp.relatedKeywords) { model.research(keyword: $0) }
                }
                .card()
            }

            if let researched = opp.researchedAt {
                Text("Researched \(researched.relativeShort). Sources: App Store, Reddit, Hacker News.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(opp.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func trendCard(_ trend: TrendSignal) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CardLabel(text: "Trend", symbol: "chart.line.uptrend.xyaxis", tint: Theme.trend)
            HStack(alignment: .firstTextBaseline) {
                Text(MoneyFormat.percent(trend.growthPercent))
                    .font(.title.weight(.bold))
                    .foregroundStyle(Theme.trend)
                Text("mentions this week vs. the 3 weeks before").font(.subheadline).foregroundStyle(.secondary)
            }
            Text(trend.mentionsBySource.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(trend.headlines, id: \.self) { headline in
                Button {
                    if let url = headline.url.flatMap(URL.init(string:)) { openURL(url) }
                } label: {
                    HStack(alignment: .top) {
                        Text("“\(headline.title)”").font(.subheadline).foregroundStyle(.primary).multilineTextAlignment(.leading)
                        Spacer()
                        Text(headline.source).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .card()
    }

    private func difficultyCard(_ opp: Opportunity, _ d: DifficultyEstimate) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CardLabel(text: "Difficulty", symbol: "hammer")
            Text("About \(d.hoursLow)–\(d.hoursHigh) hours for you")
                .font(.title3.weight(.semibold))
            if !d.drivers.isEmpty {
                Text("Because it would " + d.drivers.joined(separator: ", ") + ".")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let feature = DifficultyFeature.allCases.first(where: { opp.features[$0] == nil }) {
                Divider()
                Text("Would it \(feature.question)?").font(.subheadline.weight(.semibold))
                AnswerButtons(options: [AnswerOption("yes", "Yes"), AnswerOption("no", "No"), AnswerOption("unsure", "Unsure")],
                              tint: .secondary) { option in
                    if let answer = FeatureAnswer(rawValue: option.id) {
                        withAnimation(.snappy) { model.answerFeature(opp.id, feature, answer) }
                    }
                }
            }
        }
        .card()
    }

    private func competitionCard(_ c: CompetitionReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CardLabel(text: "Competition", symbol: "person.3", tint: Theme.attention)
            Text(c.summary).font(.subheadline)
            ForEach(c.competitors.prefix(6)) { app in
                Button {
                    if let url = app.url.flatMap(URL.init(string:)) { openURL(url) }
                } label: {
                    HStack(spacing: 12) {
                        AsyncImage(url: app.iconURL.flatMap(URL.init(string:))) { image in
                            image.resizable()
                        } placeholder: {
                            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                        }
                        .frame(width: 36, height: 36)
                        .clipShape(.rect(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                            Text(String(format: "%.1f★ · %@ ratings · %@", app.rating, app.ratingCount.formatted(.number.notation(.compactName)), app.formattedPrice))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let updated = app.lastUpdated {
                            Text(updated.relativeShort).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            if !c.praises.isEmpty {
                Text("People love: " + c.praises.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .card(tint: Theme.attention)
    }
}

/// Wrapping row of tappable chips.
struct FlowChips: View {
    let items: [String]
    var onTap: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(items, id: \.self) { item in
                Button(item) { onTap(item) }
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.trend.opacity(0.1), in: .capsule)
                    .foregroundStyle(Theme.trend)
                    .buttonStyle(.plain)
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
