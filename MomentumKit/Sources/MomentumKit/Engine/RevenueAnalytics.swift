import Foundation

public struct DailyPoint: Hashable, Sendable, Identifiable {
    public var day: DayKey
    public var amount: Double
    public var id: String { day.rawValue }

    public init(day: DayKey, amount: Double) {
        self.day = day
        self.amount = amount
    }
}

public struct RevenueAnomaly: Hashable, Sendable {
    public enum Direction: String, Sendable { case spike, drop }
    public var day: DayKey
    public var direction: Direction
    public var amount: Double
    public var baseline: Double
    public var percentChange: Double
}

public struct MoneySummary: Hashable, Sendable {
    public var yesterday: Double
    public var today: Double
    public var monthToDate: Double
    public var lastMonth: Double
    public var mrr: Double
    public var mrrIsEstimate: Bool
    public var arr: Double { mrr * 12 }
    public var last30Days: [DailyPoint]
    /// Last 7 days vs the 7 days before, in percent (nil when there is no baseline).
    public var weekTrendPercent: Double?
    public var monthEndForecast: Double
    public var next30DaysForecast: Double
    public var downloadsLast7Days: Int
    public var activeSubscriptions: Int?
    public var hasData: Bool
}

public enum RevenueAnalytics {

    public static func dailyTotals(_ entries: [RevenueEntry], projectID: UUID? = nil) -> [DayKey: Double] {
        var totals: [DayKey: Double] = [:]
        for entry in entries where projectID == nil || entry.projectID == projectID {
            totals[entry.day, default: 0] += entry.amount
        }
        return totals
    }

    public static func series(_ entries: [RevenueEntry], days: Int, endingAt end: DayKey, projectID: UUID? = nil) -> [DailyPoint] {
        let totals = dailyTotals(entries, projectID: projectID)
        let start = end.adding(days: -(days - 1), timeZone: utc)
        return DayKey.range(from: start, through: end).map { DailyPoint(day: $0, amount: totals[$0] ?? 0) }
    }

    public static func total(_ entries: [RevenueEntry], from start: DayKey, through end: DayKey, projectID: UUID? = nil) -> Double {
        entries
            .filter { $0.day >= start && $0.day <= end && (projectID == nil || $0.projectID == projectID) }
            .reduce(0) { $0 + $1.amount }
    }

    /// Ordinary least squares over the series; returns the projected sum for the next `days`.
    public static func forecast(_ points: [DailyPoint], days: Int) -> Double {
        let n = Double(points.count)
        guard n >= 7 else { return points.map(\.amount).reduce(0, +) / max(n, 1) * Double(days) }
        let xs = (0..<points.count).map(Double.init)
        let ys = points.map(\.amount)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        let sxy = zip(xs, ys).reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
        let sxx = xs.reduce(0) { $0 + ($1 - meanX) * ($1 - meanX) }
        let slope = sxx == 0 ? 0 : sxy / sxx
        let intercept = meanY - slope * meanX
        var sum = 0.0
        for i in 0..<days {
            sum += max(0, intercept + slope * (n + Double(i)))
        }
        return sum
    }

    /// Flags `day` when it deviates strongly from the previous 14 days.
    public static func anomaly(_ entries: [RevenueEntry], on day: DayKey) -> RevenueAnomaly? {
        let history = series(entries, days: 14, endingAt: day.adding(days: -1, timeZone: utc))
        let nonZeroDays = history.filter { $0.amount != 0 }.count
        guard nonZeroDays >= 7 else { return nil }
        let values = history.map(\.amount)
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
        let sd = max(sqrt(variance), mean * 0.1, 1)
        let amount = dailyTotals(entries)[day] ?? 0
        let z = (amount - mean) / sd
        let change = mean == 0 ? 0 : (amount - mean) / mean * 100
        guard abs(z) >= 2.5, abs(change) >= 20, abs(amount - mean) >= 5 else { return nil }
        return RevenueAnomaly(day: day, direction: z > 0 ? .spike : .drop, amount: amount, baseline: mean, percentChange: change)
    }

    public static func summary(_ data: MomentumData, now: Date, timeZone: TimeZone = .current) -> MoneySummary {
        let today = DayKey(now, timeZone: timeZone)
        let yesterday = today.adding(days: -1, timeZone: utc)
        let entries = data.revenue
        let monthStart = DayKey("\(today.month)-01")!
        let lastMonthEnd = monthStart.adding(days: -1, timeZone: utc)
        let lastMonthStart = DayKey("\(lastMonthEnd.month)-01")!

        let last30 = series(entries, days: 30, endingAt: yesterday)
        let last7 = last30.suffix(7).map(\.amount).reduce(0, +)
        let prior7 = last30.dropLast(7).suffix(7).map(\.amount).reduce(0, +)
        let trend: Double? = prior7 > 0 ? (last7 - prior7) / prior7 * 100 : nil

        // Prefer provider-reported MRR; fall back to subscription proceeds over the last 30 days.
        let latestMetrics = Dictionary(grouping: data.metrics, by: \.source).compactMap { $0.value.max { $0.fetchedAt < $1.fetchedAt } }
        let reportedMRR = latestMetrics.map(\.mrr).reduce(0, +)
        let estimatedMRR = entries.filter { $0.kind == .subscription && $0.day > yesterday.adding(days: -30, timeZone: utc) && $0.day <= yesterday }
            .reduce(0) { $0 + $1.amount }
        let reportedSources = Set(latestMetrics.map(\.source))
        // Avoid double counting App Store subscriptions RevenueCat already reports.
        let mrr = reportedMRR > 0 ? reportedMRR + (reportedSources.contains(.revenueCat) ? 0 : estimatedMRR) : estimatedMRR
        let activeSubs = latestMetrics.compactMap(\.activeSubscriptions)

        let mtd = total(entries, from: monthStart, through: today)
        let daysInMonth = DayKey.calendar(timeZone).range(of: .day, in: .month, for: now)?.count ?? 30
        let dayOfMonth = monthStart.days(to: today) + 1
        let avgDaily = last7 / 7
        let monthEnd = mtd + avgDaily * Double(max(0, daysInMonth - dayOfMonth))

        let downloadCutoff = today.adding(days: -7, timeZone: utc)
        let downloads7 = data.downloads.filter { $0.day >= downloadCutoff }.reduce(0) { $0 + $1.units }

        return MoneySummary(
            yesterday: total(entries, from: yesterday, through: yesterday),
            today: total(entries, from: today, through: today),
            monthToDate: mtd,
            lastMonth: total(entries, from: lastMonthStart, through: lastMonthEnd),
            mrr: mrr,
            mrrIsEstimate: reportedMRR == 0,
            last30Days: last30,
            weekTrendPercent: trend,
            monthEndForecast: monthEnd,
            next30DaysForecast: forecast(Array(last30.suffix(28)), days: 30),
            downloadsLast7Days: downloads7,
            activeSubscriptions: activeSubs.isEmpty ? nil : activeSubs.reduce(0, +),
            hasData: !entries.isEmpty || !data.metrics.isEmpty
        )
    }

    /// Revenue per project over the last 30 days, highest first.
    public static func perProject(_ data: MomentumData, now: Date) -> [(project: Project, amount: Double)] {
        let end = DayKey(now)
        let start = end.adding(days: -30, timeZone: utc)
        return data.projects.compactMap { project in
            let amount = total(data.revenue, from: start, through: end, projectID: project.id)
            return amount == 0 ? nil : (project, amount)
        }
        .sorted { $0.amount > $1.amount }
    }

    static let utc = TimeZone(identifier: "UTC")!
}

public enum MoneyFormat {
    public static func currency(_ value: Double, code: String = "USD", compact: Bool = false) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.maximumFractionDigits = (compact || abs(value) >= 1000) ? 0 : 2
        formatter.minimumFractionDigits = formatter.maximumFractionDigits == 0 ? 0 : (value == value.rounded() ? 0 : 2)
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "$%.0f", value)
    }

    public static func percent(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        return rounded > 0 ? "+\(rounded)%" : "\(rounded)%"
    }
}
