import SwiftUI
import MomentumKit

struct ReviewView: View {
    @Environment(AppModel.self) private var model
    @State private var period = 7

    var body: some View {
        let review = ReviewBuilder.review(model.data, days: period, now: Date())
        let code = model.currency
        Page {
            Picker("Period", selection: $period) {
                Text("Week").tag(7)
                Text("Month").tag(30)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 10) {
                CardLabel(text: period == 7 ? "Your week" : "Your month", symbol: "sparkles", tint: Theme.money)
                Text(review.headline)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Progress on \(review.activeDays) of \(period) days. Every one counts.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .card(tint: Theme.money)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                MetricTile(title: "Earned", value: MoneyFormat.currency(review.revenue, code: code, compact: true), tint: Theme.money)
                MetricTile(title: "vs. before", value: review.revenueChangePercent.map(MoneyFormat.percent) ?? "–",
                           tint: (review.revenueChangePercent ?? 0) >= 0 ? Theme.money : Theme.attention)
                MetricTile(title: "Focus sessions", value: "\(review.focusSessions)", tint: .accentColor)
                MetricTile(title: "Focus time", value: "\(review.focusMinutes) min", tint: .accentColor)
                MetricTile(title: "Steps done", value: "\(review.stepsCompleted)", tint: .accentColor)
                MetricTile(title: "New ideas", value: "\(review.opportunitiesFound)", tint: Theme.trend)
            }

            if !review.shipped.isEmpty || !review.stageChanges.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    CardLabel(text: "Wins", symbol: "trophy", tint: .yellow)
                    ForEach(Array((review.shipped + review.stageChanges).enumerated()), id: \.offset) { _, line in
                        Label(line, systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Theme.money)
                    }
                }
                .card()
            }

            if let top = review.topProject {
                Text("Most of your focus went to \(top).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            let weekly = model.data.pendingQuestions.filter { [.keepActive, .weeklyFocus, .interests].contains($0.kind) }
            if !weekly.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    CardLabel(text: "\(weekly.count) quick \(weekly.count == 1 ? "question" : "questions")", symbol: "questionmark.bubble", tint: Theme.attention)
                    ForEach(weekly) { question in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(question.prompt).font(.headline)
                            AnswerButtons(options: question.options) { model.answer(question.id, $0.id) }
                        }
                    }
                }
                .card(tint: Theme.attention)
            }

            recentActivity
        }
        .navigationTitle("Review")
        .toolbar { CommonToolbar(model: model) }
    }

    private var recentActivity: some View {
        let events = model.data.activity.suffix(12).reversed()
        return Group {
            if !events.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    CardLabel(text: "Recently", symbol: "clock")
                    ForEach(Array(events)) { event in
                        HStack(alignment: .firstTextBaseline) {
                            Text(event.title).font(.subheadline).lineLimit(2)
                            Spacer()
                            Text(event.date.relativeShort).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .card()
            }
        }
    }
}
