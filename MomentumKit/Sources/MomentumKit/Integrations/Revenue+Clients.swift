import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - RevenueCat

public struct RevenueCatClient: Sendable {
    let apiKey: String
    let projectID: String
    let http: HTTPClient

    public init(apiKey: String, projectID: String, http: HTTPClient) {
        self.apiKey = apiKey
        self.projectID = projectID
        self.http = http
    }

    struct Overview: Decodable {
        struct Metric: Decodable {
            let id: String
            let value: Double
        }
        let metrics: [Metric]
    }

    public func metrics(now: Date) async throws -> SubscriptionMetrics {
        let url = URL.make("https://api.revenuecat.com/v2/projects/\(projectID)/metrics/overview")
        let request = URLRequest(url, headers: ["Authorization": "Bearer \(apiKey)", "Accept": "application/json"])
        let overview = try await http.json(Overview.self, request, service: "RevenueCat")
        return RevenueCatClient.metrics(from: overview, now: now)
    }

    static func metrics(from overview: Overview, now: Date) -> SubscriptionMetrics {
        func value(_ id: String) -> Double? { overview.metrics.first { $0.id == id }?.value }
        return SubscriptionMetrics(
            source: .revenueCat,
            mrr: value("mrr") ?? 0,
            activeSubscriptions: value("active_subscriptions").map { Int($0) },
            activeTrials: value("active_trials").map { Int($0) },
            revenueLast28Days: value("revenue"),
            newCustomersLast28Days: value("new_customers").map { Int($0) },
            fetchedAt: now
        )
    }

    public static func parseMetrics(_ data: Data, now: Date) throws -> SubscriptionMetrics {
        metrics(from: try JSONCoding.decoder.decode(Overview.self, from: data), now: now)
    }
}

// MARK: - Stripe

public struct StripeClient: Sendable {
    let apiKey: String
    let http: HTTPClient

    public init(apiKey: String, http: HTTPClient) {
        self.apiKey = apiKey
        self.http = http
    }

    var headers: [String: String] { ["Authorization": "Bearer \(apiKey)"] }

    struct Page<T: Decodable>: Decodable {
        let data: [T]
        let hasMore: Bool
        enum CodingKeys: String, CodingKey { case data, hasMore = "has_more" }
    }

    public struct BalanceTransaction: Decodable, Sendable {
        public let id: String
        public let net: Int
        public let currency: String
        public let created: Int
        public let type: String
    }

    public func balanceTransactions(since: Date, maxPages: Int = 10) async throws -> [BalanceTransaction] {
        var all: [BalanceTransaction] = []
        var cursor: String?
        for _ in 0..<maxPages {
            var query = [("created[gte]", String(Int(since.timeIntervalSince1970))), ("limit", "100")]
            if let cursor { query.append(("starting_after", cursor)) }
            let page = try await http.json(Page<BalanceTransaction>.self, URLRequest(URL.make("https://api.stripe.com/v1/balance_transactions", query), headers: headers), service: "Stripe")
            all += page.data
            guard page.hasMore, let last = page.data.last else { break }
            cursor = last.id
        }
        return all
    }

    /// Net income per day (charges minus refunds, after Stripe fees), in the base currency.
    public static func entries(_ transactions: [BalanceTransaction], fx: FXRates, timeZone: TimeZone = .current) -> [RevenueEntry] {
        let income: Set<String> = ["charge", "payment", "refund", "payment_refund", "payment_failure_refund"]
        var byDay: [DayKey: (purchase: Double, refund: Double, units: Int)] = [:]
        for tx in transactions where income.contains(tx.type) {
            let amount = Double(tx.net) / pow(10, Double(FXRates.minorUnits(tx.currency)))
            guard let converted = fx.convert(amount, from: tx.currency.uppercased()) else { continue }
            let day = DayKey(Date(timeIntervalSince1970: TimeInterval(tx.created)), timeZone: timeZone)
            var bucket = byDay[day] ?? (0, 0, 0)
            if converted < 0 { bucket.refund += converted } else { bucket.purchase += converted; bucket.units += 1 }
            byDay[day] = bucket
        }
        return byDay.flatMap { day, bucket -> [RevenueEntry] in
            var entries: [RevenueEntry] = []
            if bucket.purchase != 0 {
                entries.append(RevenueEntry(day: day, source: .stripe, kind: .purchase, amount: (bucket.purchase * 100).rounded() / 100, units: bucket.units))
            }
            if bucket.refund != 0 {
                entries.append(RevenueEntry(day: day, source: .stripe, kind: .refund, amount: (bucket.refund * 100).rounded() / 100))
            }
            return entries
        }
        .sorted { ($0.day, $0.kind.rawValue) < ($1.day, $1.kind.rawValue) }
    }

    public struct Subscription: Decodable, Sendable {
        public struct Items: Decodable, Sendable { public let data: [Item] }
        public struct Item: Decodable, Sendable {
            public let quantity: Int?
            public let price: Price
        }
        public struct Price: Decodable, Sendable {
            public let unitAmount: Int?
            public let currency: String
            public let recurring: Recurring?
            enum CodingKeys: String, CodingKey { case unitAmount = "unit_amount", currency, recurring }
        }
        public struct Recurring: Decodable, Sendable {
            public let interval: String
            public let intervalCount: Int
            enum CodingKeys: String, CodingKey { case interval, intervalCount = "interval_count" }
        }
        public let id: String
        public let items: Items
    }

    public func activeSubscriptions(maxPages: Int = 10) async throws -> [Subscription] {
        var all: [Subscription] = []
        var cursor: String?
        for _ in 0..<maxPages {
            var query = [("status", "active"), ("limit", "100")]
            if let cursor { query.append(("starting_after", cursor)) }
            let request = URLRequest(URL.make("https://api.stripe.com/v1/subscriptions", query), headers: headers)
            let page = try await http.json(Page<Subscription>.self, request, service: "Stripe")
            all += page.data
            guard page.hasMore, let last = page.data.last else { break }
            cursor = last.id
        }
        return all
    }

    public static func mrr(_ subscriptions: [Subscription], fx: FXRates) -> Double {
        var total = 0.0
        for sub in subscriptions {
            for item in sub.items.data {
                guard let recurring = item.price.recurring, let unit = item.price.unitAmount else { continue }
                let perInterval = Double(unit * (item.quantity ?? 1)) / pow(10, Double(FXRates.minorUnits(item.price.currency)))
                let monthsPerInterval: Double
                switch recurring.interval {
                case "day": monthsPerInterval = Double(recurring.intervalCount) * 12 / 365
                case "week": monthsPerInterval = Double(recurring.intervalCount) * 12 / 52
                case "year": monthsPerInterval = Double(recurring.intervalCount) * 12
                default: monthsPerInterval = Double(recurring.intervalCount)
                }
                guard monthsPerInterval > 0, let converted = fx.convert(perInterval / monthsPerInterval, from: item.price.currency.uppercased()) else { continue }
                total += converted
            }
        }
        return (total * 100).rounded() / 100
    }
}

// MARK: - Currency conversion

public struct FXRates: Codable, Hashable, Sendable {
    public var base: String
    /// Units of each currency per 1 unit of `base`.
    public var rates: [String: Double]
    public var fetchedAt: Date

    public init(base: String, rates: [String: Double], fetchedAt: Date) {
        self.base = base.uppercased()
        self.rates = rates
        self.fetchedAt = fetchedAt
    }

    public static func identity(_ base: String) -> FXRates { FXRates(base: base, rates: [:], fetchedAt: .distantPast) }

    public func convert(_ amount: Double, from currency: String) -> Double? {
        let code = currency.uppercased()
        if code == base { return amount }
        guard let rate = rates[code], rate > 0 else { return nil }
        return amount / rate
    }

    static let zeroDecimal: Set<String> = ["BIF", "CLP", "DJF", "GNF", "JPY", "KMF", "KRW", "MGA", "PYG", "RWF", "UGX", "VND", "VUV", "XAF", "XOF", "XPF"]

    static func minorUnits(_ currency: String) -> Int { zeroDecimal.contains(currency.uppercased()) ? 0 : 2 }

    /// Free ECB reference rates (no key). Cached by the app for a day.
    public static func fetch(base: String, http: HTTPClient, now: Date) async throws -> FXRates {
        struct Response: Decodable { let base: String; let rates: [String: Double] }
        let url = URL.make("https://api.frankfurter.dev/v1/latest", [("base", base.uppercased())])
        let response = try await http.json(Response.self, URLRequest(url), service: "exchange rates")
        return FXRates(base: response.base, rates: response.rates, fetchedAt: now)
    }
}
