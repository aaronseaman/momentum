import Foundation

public struct MoneyAnswer: Hashable, Sendable {
    public var text: String
    public var value: Double?
    public var series: [DailyPoint]
}

/// Answers plain-language money questions ("How much did I make this month?") locally.
public enum MoneyQuery {
    public static func answer(_ question: String, data: MomentumData, now: Date, calendar: Calendar = .current) -> MoneyAnswer {
        let q = question.lowercased()
        let words = Set(q.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let utc = RevenueAnalytics.utc
        let today = DayKey(now)
        let code = data.preferences.baseCurrency
        let project = data.projects.first { q.contains($0.name.lowercased()) }
        let scope = project.map { " from \($0.name)" } ?? ""
        let summary = RevenueAnalytics.summary(data, now: now)

        func money(_ v: Double) -> String { MoneyFormat.currency(v, code: code) }
        func range(_ start: DayKey, _ end: DayKey, _ label: String) -> MoneyAnswer {
            let value = RevenueAnalytics.total(data.revenue, from: start, through: end, projectID: project?.id)
            let days = max(1, start.days(to: end) + 1)
            let series = RevenueAnalytics.series(data.revenue, days: min(max(days, 7), 90), endingAt: end, projectID: project?.id)
            return MoneyAnswer(text: "You made \(money(value))\(scope) \(label).", value: value, series: series)
        }

        if words.contains("mrr") || q.contains("recurring") {
            let note = summary.mrrIsEstimate ? " (estimated from subscription proceeds)" : ""
            return MoneyAnswer(text: "MRR is \(money(summary.mrr))\(note).", value: summary.mrr, series: summary.last30Days)
        }
        if words.contains("arr") || q.contains("annual") {
            return MoneyAnswer(text: "ARR is \(money(summary.arr)).", value: summary.arr, series: summary.last30Days)
        }
        if q.contains("forecast") || q.contains("end of the month") || q.contains("end of month") || q.contains("will i") || q.contains("on track") {
            return MoneyAnswer(text: "At this pace you'll end the month around \(money(summary.monthEndForecast)).",
                               value: summary.monthEndForecast, series: summary.last30Days)
        }
        if q.contains("download") {
            return MoneyAnswer(text: "\(summary.downloadsLast7Days) downloads in the last 7 days.", value: Double(summary.downloadsLast7Days), series: [])
        }
        if q.contains("yesterday") {
            let y = today.adding(days: -1, timeZone: utc)
            return range(y, y, "yesterday")
        }
        if q.contains("today") {
            return range(today, today, "today")
        }
        if q.contains("last month") {
            let monthStart = DayKey("\(today.month)-01")!
            let end = monthStart.adding(days: -1, timeZone: utc)
            return range(DayKey("\(end.month)-01")!, end, "last month")
        }
        if q.contains("last week") {
            let weekStart = DayKey(calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now)
            return range(weekStart.adding(days: -7, timeZone: utc), weekStart.adding(days: -1, timeZone: utc), "last week")
        }
        if q.contains("this week") || q.contains("week") {
            let weekStart = DayKey(calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now)
            return range(weekStart, today, "this week")
        }
        if q.contains("year") {
            return range(DayKey("\(today.rawValue.prefix(4))-01-01")!, today, "this year")
        }
        if q.contains("30 days") || q.contains("thirty days") {
            return range(today.adding(days: -29, timeZone: utc), today, "in the last 30 days")
        }
        if q.contains("all time") || q.contains("ever") || q.contains("total") {
            let first = data.revenue.map(\.day).min() ?? today
            return range(first, today, "all time")
        }
        // Default: this month, the most common question.
        return range(DayKey("\(today.month)-01")!, today, "this month")
    }
}
