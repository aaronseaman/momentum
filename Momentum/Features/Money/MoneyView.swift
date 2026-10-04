import SwiftUI
import Charts
import MomentumKit

struct MoneyView: View {
    @Environment(AppModel.self) private var model
    @State private var question = ""
    @State private var answer: MoneyAnswer?
    #if os(macOS)
    @Environment(\.openSettings) private var openSettingsAction
    #endif

    var body: some View {
        let money = model.money
        let code = model.currency
        Page {
            if !money.hasData {
                EmptyState(symbol: "chart.line.uptrend.xyaxis", title: "No income connected",
                           message: "Connect App Store Connect, RevenueCat or Stripe once. Momentum keeps everything up to date after that.",
                           actionTitle: "Open Settings") { openSettings() }
            } else {
                askCard

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    MetricTile(title: "Yesterday", value: MoneyFormat.currency(money.yesterday, code: code), tint: Theme.money)
                    MetricTile(title: money.mrrIsEstimate ? "MRR (est.)" : "MRR", value: MoneyFormat.currency(money.mrr, code: code, compact: true), tint: Theme.money)
                    MetricTile(title: "ARR", value: MoneyFormat.currency(money.arr, code: code, compact: true), tint: Theme.money)
                    MetricTile(title: "This month", value: MoneyFormat.currency(money.monthToDate, code: code, compact: true), tint: Theme.money)
                    MetricTile(title: "Month-end forecast", value: MoneyFormat.currency(money.monthEndForecast, code: code, compact: true), tint: .secondary)
                    MetricTile(title: "Downloads · 7d", value: money.downloadsLast7Days.formatted(), tint: Theme.trend)
                    if let subs = money.activeSubscriptions {
                        MetricTile(title: "Active subscribers", value: subs.formatted(), tint: Theme.trend)
                    }
                    MetricTile(title: "Last month", value: MoneyFormat.currency(money.lastMonth, code: code, compact: true), tint: .secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        CardLabel(text: "Last 30 days", symbol: "chart.xyaxis.line", tint: Theme.money)
                        Spacer()
                        if let trend = money.weekTrendPercent {
                            Text("\(MoneyFormat.percent(trend)) week over week")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(trend >= 0 ? Theme.money : Theme.attention)
                        }
                    }
                    Chart(money.last30Days) { point in
                        BarMark(x: .value("Day", point.day.date(), unit: .day), y: .value("Revenue", point.amount))
                            .foregroundStyle(Theme.money.gradient)
                            .cornerRadius(3)
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let amount = value.as(Double.self) { Text(MoneyFormat.currency(amount, code: code, compact: true)) }
                            }
                        }
                    }
                    .frame(height: 200)
                    .accessibilityLabel("Revenue chart for the last 30 days")
                    Text("Next 30 days at this pace: about \(MoneyFormat.currency(money.next30DaysForecast, code: code, compact: true)).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .card()

                let perProject = RevenueAnalytics.perProject(model.data, now: Date())
                if !perProject.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        CardLabel(text: "By project · 30 days", symbol: "square.stack.3d.up")
                        ForEach(perProject, id: \.project.id) { item in
                            HStack {
                                Image(systemName: item.project.symbol).foregroundStyle(Theme.money).frame(width: 22)
                                Text(item.project.name)
                                Spacer()
                                Text(MoneyFormat.currency(item.amount, code: code)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                        }
                    }
                    .card()
                }

                sourcesFooter
            }
        }
        .navigationTitle("Money")
        .toolbar { CommonToolbar(model: model) }
        .refreshable { await model.refresh() }
    }

    private var askCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.text.bubble.right").foregroundStyle(Theme.money)
                TextField("Ask: “How much did I make this month?”", text: $question)
                    .textFieldStyle(.plain)
                    .onSubmit(ask)
                    .submitLabel(.search)
                if !question.isEmpty {
                    Button("Ask", action: ask).buttonStyle(.borderless)
                }
            }
            if let answer {
                Text(answer.text).font(.title3.weight(.semibold))
                if answer.series.count > 1 {
                    Sparkline(points: answer.series).frame(height: 44)
                }
            }
        }
        .card(tint: Theme.money)
    }

    private var sourcesFooter: some View {
        let connected = [IntegrationKind.appStoreConnect, .revenueCat, .stripe].filter { model.data.integration($0).isConnected }
        return Text("From \(connected.map(\.title).joined(separator: ", ")). App Store figures are your proceeds after Apple's commission, converted to \(model.currency).")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func ask() {
        guard !question.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        withAnimation(.snappy) {
            answer = MoneyQuery.answer(question, data: model.data, now: Date())
        }
    }

    private func openSettings() {
        #if os(iOS)
        model.showSettings = true
        #else
        openSettingsAction()
        #endif
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.cardBackground, in: .rect(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
