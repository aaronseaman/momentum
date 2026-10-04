import Foundation

public struct Brief: Hashable, Sendable {
    public var title: String
    public var body: String
}

/// Notification copy. Short, kind, and specific — never guilt.
public enum Briefs {

    public static func morning(_ data: MomentumData, now: Date) -> Brief {
        var lines: [String] = []
        let money = RevenueAnalytics.summary(data, now: now)
        if money.hasData {
            lines.append("Revenue yesterday: \(MoneyFormat.currency(money.yesterday, code: data.preferences.baseCurrency)).")
        }
        if let trend = topTrend(data) {
            lines.append("Trend: \(trend.title) \(trendPhrase(trend)).")
        }
        if let next = Planner.nextAction(data, now: now) {
            lines.append("Next action: \(lowercasedFirst(next.title)).")
        }
        if let q = QuestionEngine.current(data, now: now) {
            lines.append("One question: \(q.prompt)")
        }
        return Brief(title: "Good morning", body: lines.isEmpty ? "A fresh day. One small step is enough." : lines.joined(separator: " "))
    }

    public static func midday(_ data: MomentumData, now: Date) -> Brief? {
        guard let next = Planner.nextAction(data, now: now) else { return nil }
        return Brief(title: "Still up for this?", body: "\(next.title) — \(next.minutes) min.")
    }

    public static func evening(_ data: MomentumData, now: Date) -> Brief {
        let today = DayKey(now)
        let sessions = data.focusSessions.filter { DayKey($0.startedAt) == today && $0.completed }.count
        var lines: [String] = []
        switch sessions {
        case 0: lines.append("Rest counts too.")
        case 1: lines.append("You did 1 focus session.")
        default: lines.append("You did \(sessions) focus sessions.")
        }
        let builds = data.projects.filter { DayKey($0.signals.ciUpdatedAt ?? .distantPast) == today }
        if builds.contains(where: { $0.signals.ciStatus == .success }) { lines.append("Build succeeded.") }
        let money = RevenueAnalytics.summary(data, now: now)
        if let trend = money.weekTrendPercent, abs(trend) >= 5 {
            lines.append("Revenue \(trend > 0 ? "up" : "down") \(Int(abs(trend).rounded()))% this week.")
        }
        lines.append("Want tomorrow's plan?")
        return Brief(title: "Today, wrapped", body: lines.joined(separator: " "))
    }

    public static func weekly(_ data: MomentumData, now: Date) -> Brief {
        let review = ReviewBuilder.review(data, days: 7, now: now)
        return Brief(title: "Your week", body: review.headline)
    }

    static func topTrend(_ data: MomentumData) -> Opportunity? {
        data.opportunities.filter { $0.isVisible && $0.trend != nil }
            .max { ($0.trend?.growthPercent ?? 0) < ($1.trend?.growthPercent ?? 0) }
    }

    static func trendPhrase(_ opp: Opportunity) -> String {
        let growth = Int((opp.trend?.growthPercent ?? 0).rounded())
        return growth >= 0 ? "up \(growth)%" : "down \(abs(growth))%"
    }

    static func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        // Keep proper nouns and acronyms ("App Store", "TestFlight") intact.
        let secondIsUpper = text.dropFirst().first?.isUppercase ?? false
        return secondIsUpper ? text : first.lowercased() + text.dropFirst()
    }
}

public struct PeriodReview: Hashable, Sendable {
    public var days: Int
    public var revenue: Double
    public var previousRevenue: Double
    public var focusSessions: Int
    public var focusMinutes: Int
    public var stepsCompleted: Int
    public var shipped: [String]
    public var stageChanges: [String]
    public var opportunitiesFound: Int
    public var topProject: String?
    public var activeDays: Int
    public var headline: String

    public var revenueChangePercent: Double? {
        previousRevenue > 0 ? (revenue - previousRevenue) / previousRevenue * 100 : nil
    }
}

public enum ReviewBuilder {
    public static func review(_ data: MomentumData, days: Int, now: Date) -> PeriodReview {
        let utc = RevenueAnalytics.utc
        let end = DayKey(now)
        let start = end.adding(days: -(days - 1), timeZone: utc)
        let prevEnd = start.adding(days: -1, timeZone: utc)
        let prevStart = prevEnd.adding(days: -(days - 1), timeZone: utc)
        let since = now.addingTimeInterval(-Double(days) * 86_400)

        let sessions = data.focusSessions.filter { $0.startedAt >= since && $0.completed }
        let events = data.activity.filter { $0.date >= since }
        let shipped = events.filter { $0.kind == .release || ($0.kind == .storeStateChanged && $0.title.contains("live")) }.map(\.title)
        let stageChanges = events.filter { $0.kind == .stageChanged }.map(\.title)
        let found = data.opportunities.filter { $0.createdAt >= since }.count
        let steps = events.filter { $0.kind == .stepCompleted }.count

        var minutesByProject: [UUID: Int] = [:]
        for s in sessions { if let p = s.projectID { minutesByProject[p, default: 0] += s.actualMinutes } }
        let top = minutesByProject.max { $0.value < $1.value }.flatMap { data.project($0.key)?.name }
        let activeDays = Set(sessions.map { DayKey($0.startedAt) } + events.filter { $0.kind == .stepCompleted }.map { DayKey($0.date) }).count

        let revenue = RevenueAnalytics.total(data.revenue, from: start, through: end)
        let previous = RevenueAnalytics.total(data.revenue, from: prevStart, through: prevEnd)

        var parts: [String] = []
        if !shipped.isEmpty { parts.append("You shipped \(shipped.count) \(shipped.count == 1 ? "update" : "updates")") }
        if revenue != 0 { parts.append("earned \(MoneyFormat.currency(revenue, code: data.preferences.baseCurrency, compact: true))") }
        if found > 0 { parts.append("found \(found) new \(found == 1 ? "opportunity" : "opportunities")") }
        if !sessions.isEmpty { parts.append("focused \(sessions.count) \(sessions.count == 1 ? "time" : "times")") }
        var headline = parts.isEmpty ? "A quiet stretch. That's allowed." : parts.joined(separator: ", ") + "."
        headline = headline.prefix(1).uppercased() + headline.dropFirst()

        return PeriodReview(
            days: days,
            revenue: revenue,
            previousRevenue: previous,
            focusSessions: sessions.count,
            focusMinutes: sessions.reduce(0) { $0 + $1.actualMinutes },
            stepsCompleted: steps,
            shipped: shipped,
            stageChanges: stageChanges,
            opportunitiesFound: found,
            topProject: top,
            activeDays: activeDays,
            headline: headline
        )
    }

    /// Forgiving streak: days with any progress in the last `window` days. Never "resets".
    public static func momentumDays(_ data: MomentumData, window: Int = 14, now: Date) -> Int {
        let since = now.addingTimeInterval(-Double(window) * 86_400)
        let days = data.focusSessions.filter { $0.completed && $0.startedAt >= since }.map { DayKey($0.startedAt) }
            + data.activity.filter { $0.kind == .stepCompleted && $0.date >= since }.map { DayKey($0.date) }
        return Set(days).count
    }
}
