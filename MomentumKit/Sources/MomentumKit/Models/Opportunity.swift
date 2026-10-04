import Foundation

public enum OpportunityStatus: String, Codable, Sendable {
    case candidate, researched, starred, dismissed, promoted
}

public struct TrendSignal: Codable, Hashable, Sendable {
    public var mentionsThisWeek: Int
    /// Average weekly mentions over the three weeks before this one.
    public var priorWeeklyAverage: Double
    public var mentionsBySource: [String: Int]
    public var headlines: [Headline]
    public var measuredAt: Date

    public init(mentionsThisWeek: Int, priorWeeklyAverage: Double, mentionsBySource: [String: Int],
                headlines: [Headline], measuredAt: Date) {
        self.mentionsThisWeek = mentionsThisWeek
        self.priorWeeklyAverage = priorWeeklyAverage
        self.mentionsBySource = mentionsBySource
        self.headlines = headlines
        self.measuredAt = measuredAt
    }

    public var totalMentions: Int { mentionsBySource.values.reduce(0, +) }

    /// Week-over-baseline growth in percent. Uses a floor of 1 to avoid division blow-ups.
    public var growthPercent: Double {
        let base = max(priorWeeklyAverage, 1)
        return (Double(mentionsThisWeek) - base) / base * 100
    }
}

public struct Headline: Codable, Hashable, Sendable {
    public var title: String
    public var source: String
    public var url: String?
    public var date: Date

    public init(title: String, source: String, url: String?, date: Date) {
        self.title = title
        self.source = source
        self.url = url
        self.date = date
    }
}

public struct Competitor: Codable, Hashable, Identifiable, Sendable {
    public var id: Int
    public var name: String
    public var seller: String
    public var rating: Double
    public var ratingCount: Int
    public var price: Double
    public var formattedPrice: String
    public var lastUpdated: Date?
    public var releaseDate: Date?
    public var genre: String
    public var url: String?
    public var iconURL: String?

    public init(id: Int, name: String, seller: String, rating: Double, ratingCount: Int, price: Double,
                formattedPrice: String, lastUpdated: Date?, releaseDate: Date?, genre: String,
                url: String?, iconURL: String?) {
        self.id = id
        self.name = name
        self.seller = seller
        self.rating = rating
        self.ratingCount = ratingCount
        self.price = price
        self.formattedPrice = formattedPrice
        self.lastUpdated = lastUpdated
        self.releaseDate = releaseDate
        self.genre = genre
        self.url = url
        self.iconURL = iconURL
    }
}

public struct Review: Codable, Hashable, Sendable {
    public var rating: Int
    public var title: String
    public var body: String
    public var date: Date?

    public init(rating: Int, title: String, body: String, date: Date?) {
        self.rating = rating
        self.title = title
        self.body = body
        self.date = date
    }
}

public struct CompetitionReport: Codable, Hashable, Sendable {
    public var competitors: [Competitor]
    /// 1 (wide open) … 10 (crowded with strong, fresh incumbents).
    public var score: Int
    public var complaints: [String]
    public var praises: [String]
    public var gap: String?
    public var summary: String

    public init(competitors: [Competitor], score: Int, complaints: [String], praises: [String], gap: String?, summary: String) {
        self.competitors = competitors
        self.score = score
        self.complaints = complaints
        self.praises = praises
        self.gap = gap
        self.summary = summary
    }
}

public enum DifficultyFeature: String, Codable, CodingKeyRepresentable, CaseIterable, Sendable {
    case realtimeVideo, ai, cloudSync, payments, accounts, compliance, hardware

    public var question: String {
        switch self {
        case .realtimeVideo: "need real-time video or audio"
        case .ai: "use AI"
        case .cloudSync: "need cloud sync or a backend"
        case .payments: "need subscriptions or payments"
        case .accounts: "need user accounts or social features"
        case .compliance: "handle health, finance or kids' data"
        case .hardware: "rely on sensors, Bluetooth or the camera"
        }
    }

    /// Added difficulty points when the feature is required.
    public var weight: Double {
        switch self {
        case .realtimeVideo: 3
        case .ai: 1.5
        case .cloudSync: 2
        case .payments: 1
        case .accounts: 1.5
        case .compliance: 2
        case .hardware: 1
        }
    }

    /// Keyword hints used to infer the feature without asking.
    var hints: [String] {
        switch self {
        case .realtimeVideo: ["video", "stream", "live", "call", "camera feed", "webcam", "voice chat"]
        case .ai: ["ai", "gpt", "assistant", "chatbot", "smart", "generate", "summar"]
        case .cloudSync: ["sync", "share", "family", "team", "collab", "shared", "multiplayer", "group"]
        case .payments: ["subscription", "budget", "invoice", "payment", "pay "]
        case .accounts: ["social", "friends", "community", "dating", "chat", "network"]
        case .compliance: ["health", "medical", "therapy", "bank", "finance", "tax", "kids", "child", "baby", "medication"]
        case .hardware: ["scanner", "scan", "bluetooth", "sensor", "camera", "ar ", "lidar", "nfc", "step counter"]
        }
    }
}

public enum FeatureAnswer: String, Codable, Sendable {
    case yes, no, unsure
}

public struct DifficultyEstimate: Codable, Hashable, Sendable {
    public var score: Int
    public var hoursLow: Int
    public var hoursHigh: Int
    public var drivers: [String]

    public init(score: Int, hoursLow: Int, hoursHigh: Int, drivers: [String]) {
        self.score = score
        self.hoursLow = hoursLow
        self.hoursHigh = hoursHigh
        self.drivers = drivers
    }
}

public struct Opportunity: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var keyword: String
    public var relatedKeywords: [String]
    public var tags: [String]
    public var source: String
    public var status: OpportunityStatus
    public var createdAt: Date
    public var researchedAt: Date?
    public var trend: TrendSignal?
    public var competition: CompetitionReport?
    public var features: [DifficultyFeature: FeatureAnswer]
    public var difficulty: DifficultyEstimate?
    public var summary: String?
    /// A friendlier summary written by AI, when enabled. Preferred over `summary` in the UI.
    public var aiSummary: String?
    public var momentumScore: Int?
    public var opportunityScore: Int?

    public init(id: UUID = UUID(), keyword: String, relatedKeywords: [String] = [], tags: [String] = [],
                source: String, status: OpportunityStatus = .candidate, createdAt: Date = Date()) {
        self.id = id
        self.keyword = keyword
        self.relatedKeywords = relatedKeywords
        self.tags = tags
        self.source = source
        self.status = status
        self.createdAt = createdAt
        self.researchedAt = nil
        self.trend = nil
        self.competition = nil
        self.features = [:]
        self.difficulty = nil
        self.summary = nil
        self.aiSummary = nil
        self.momentumScore = nil
        self.opportunityScore = nil
    }

    public var title: String {
        keyword.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    public var isVisible: Bool { status != .dismissed && status != .promoted }

    public var displaySummary: String? { aiSummary ?? summary }

    public func needsResearch(now: Date) -> Bool {
        guard isVisible else { return false }
        guard let researchedAt else { return true }
        return now.days(since: researchedAt) >= 3
    }
}
