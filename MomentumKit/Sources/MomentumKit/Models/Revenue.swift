import Foundation

public enum RevenueSource: String, Codable, CaseIterable, Sendable {
    case appStore, revenueCat, stripe

    public var title: String {
        switch self {
        case .appStore: "App Store"
        case .revenueCat: "RevenueCat"
        case .stripe: "Stripe"
        }
    }
}

public enum RevenueKind: String, Codable, Sendable {
    case purchase, subscription, refund, other
}

/// One aggregated line of income for a day, already converted to the base currency.
public struct RevenueEntry: Codable, Hashable, Sendable {
    public var day: DayKey
    public var source: RevenueSource
    public var kind: RevenueKind
    /// Net proceeds in the base currency (negative for refunds).
    public var amount: Double
    public var units: Int
    /// Store/app identifier the money belongs to (App Store apple ID, Stripe product, …).
    public var appIdentifier: String?
    public var appName: String?
    public var projectID: UUID?

    public init(day: DayKey, source: RevenueSource, kind: RevenueKind, amount: Double, units: Int = 0,
                appIdentifier: String? = nil, appName: String? = nil, projectID: UUID? = nil) {
        self.day = day
        self.source = source
        self.kind = kind
        self.amount = amount
        self.units = units
        self.appIdentifier = appIdentifier
        self.appName = appName
        self.projectID = projectID
    }
}

/// Daily download counts (from App Store Connect sales reports).
public struct DownloadEntry: Codable, Hashable, Sendable {
    public var day: DayKey
    public var units: Int
    public var appIdentifier: String?
    public var projectID: UUID?

    public init(day: DayKey, units: Int, appIdentifier: String?, projectID: UUID? = nil) {
        self.day = day
        self.units = units
        self.appIdentifier = appIdentifier
        self.projectID = projectID
    }
}

/// Point-in-time subscription metrics reported by a provider.
public struct SubscriptionMetrics: Codable, Hashable, Sendable {
    public var source: RevenueSource
    public var mrr: Double
    public var activeSubscriptions: Int?
    public var activeTrials: Int?
    public var revenueLast28Days: Double?
    public var newCustomersLast28Days: Int?
    public var fetchedAt: Date

    public init(source: RevenueSource, mrr: Double, activeSubscriptions: Int? = nil, activeTrials: Int? = nil,
                revenueLast28Days: Double? = nil, newCustomersLast28Days: Int? = nil, fetchedAt: Date) {
        self.source = source
        self.mrr = mrr
        self.activeSubscriptions = activeSubscriptions
        self.activeTrials = activeTrials
        self.revenueLast28Days = revenueLast28Days
        self.newCustomersLast28Days = newCustomersLast28Days
        self.fetchedAt = fetchedAt
    }
}
