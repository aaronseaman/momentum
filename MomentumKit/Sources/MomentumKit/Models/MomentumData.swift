import Foundation

public enum IntegrationKind: String, Codable, CodingKeyRepresentable, CaseIterable, Identifiable, Sendable {
    case github, appStoreConnect, revenueCat, stripe

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .github: "GitHub"
        case .appStoreConnect: "App Store Connect"
        case .revenueCat: "RevenueCat"
        case .stripe: "Stripe"
        }
    }
}

public struct IntegrationState: Codable, Hashable, Sendable {
    public var isConnected: Bool
    public var connectedAt: Date?
    public var lastSyncAt: Date?
    public var lastError: String?
    /// Who/what is connected, e.g. a GitHub login. Never a secret.
    public var accountLabel: String?

    public init(isConnected: Bool = false, connectedAt: Date? = nil, lastSyncAt: Date? = nil, lastError: String? = nil, accountLabel: String? = nil) {
        self.isConnected = isConnected
        self.connectedAt = connectedAt
        self.lastSyncAt = lastSyncAt
        self.lastError = lastError
        self.accountLabel = accountLabel
    }
}

public enum AIMode: String, Codable, CaseIterable, Sendable {
    case off, onDevice, claude

    public var title: String {
        switch self {
        case .off: "Built-in rules"
        case .onDevice: "On-device (Apple Intelligence)"
        case .claude: "Claude (your API key)"
        }
    }
}

public struct ClockTime: Codable, Hashable, Sendable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }
}

public struct Preferences: Codable, Hashable, Sendable {
    public var morningBrief: Bool = true
    public var morningTime = ClockTime(hour: 7, minute: 30)
    public var middayCheckIn: Bool = true
    public var middayTime = ClockTime(hour: 13, minute: 30)
    public var eveningSummary: Bool = true
    public var eveningTime = ClockTime(hour: 18, minute: 0)
    public var weeklyReview: Bool = true
    /// 1 = Sunday … 7 = Saturday (Gregorian weekday).
    public var weeklyReviewWeekday: Int = 1
    public var weeklyReviewTime = ClockTime(hour: 10, minute: 0)
    public var alerts: Bool = true
    public var maxQuestionsPerDay: Int = 3
    public var focusMinutes: Int = 25
    public var ambientSound: Bool = true
    public var calendarBlocking: Bool = false
    public var focusHour: Int = 10
    public var aiMode: AIMode = .off
    public var researchCountry: String = "us"
    public var useReddit: Bool = true
    public var useHackerNews: Bool = true
    public var baseCurrency: String = "USD"
    public var stallDays: Int = 8

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        morningBrief = try c.decodeIfPresent(Bool.self, forKey: .morningBrief) ?? d.morningBrief
        morningTime = try c.decodeIfPresent(ClockTime.self, forKey: .morningTime) ?? d.morningTime
        middayCheckIn = try c.decodeIfPresent(Bool.self, forKey: .middayCheckIn) ?? d.middayCheckIn
        middayTime = try c.decodeIfPresent(ClockTime.self, forKey: .middayTime) ?? d.middayTime
        eveningSummary = try c.decodeIfPresent(Bool.self, forKey: .eveningSummary) ?? d.eveningSummary
        eveningTime = try c.decodeIfPresent(ClockTime.self, forKey: .eveningTime) ?? d.eveningTime
        weeklyReview = try c.decodeIfPresent(Bool.self, forKey: .weeklyReview) ?? d.weeklyReview
        weeklyReviewWeekday = try c.decodeIfPresent(Int.self, forKey: .weeklyReviewWeekday) ?? d.weeklyReviewWeekday
        weeklyReviewTime = try c.decodeIfPresent(ClockTime.self, forKey: .weeklyReviewTime) ?? d.weeklyReviewTime
        alerts = try c.decodeIfPresent(Bool.self, forKey: .alerts) ?? d.alerts
        maxQuestionsPerDay = try c.decodeIfPresent(Int.self, forKey: .maxQuestionsPerDay) ?? d.maxQuestionsPerDay
        focusMinutes = try c.decodeIfPresent(Int.self, forKey: .focusMinutes) ?? d.focusMinutes
        ambientSound = try c.decodeIfPresent(Bool.self, forKey: .ambientSound) ?? d.ambientSound
        calendarBlocking = try c.decodeIfPresent(Bool.self, forKey: .calendarBlocking) ?? d.calendarBlocking
        focusHour = try c.decodeIfPresent(Int.self, forKey: .focusHour) ?? d.focusHour
        aiMode = try c.decodeIfPresent(AIMode.self, forKey: .aiMode) ?? d.aiMode
        researchCountry = try c.decodeIfPresent(String.self, forKey: .researchCountry) ?? d.researchCountry
        useReddit = try c.decodeIfPresent(Bool.self, forKey: .useReddit) ?? d.useReddit
        useHackerNews = try c.decodeIfPresent(Bool.self, forKey: .useHackerNews) ?? d.useHackerNews
        baseCurrency = try c.decodeIfPresent(String.self, forKey: .baseCurrency) ?? d.baseCurrency
        stallDays = try c.decodeIfPresent(Int.self, forKey: .stallDays) ?? d.stallDays
    }
}

/// What Momentum has learned about the person, mostly from their answers.
public struct UserProfile: Codable, Hashable, Sendable {
    public var hasOnboarded: Bool = false
    public var interests: [String] = []
    /// Learned preference per topic tag (-1 … 1). Updated by every research/dismiss answer.
    public var tagWeights: [String: Double] = [:]
    public var lastOpenedAt: Date?
    public var focusProjectID: UUID?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hasOnboarded = try c.decodeIfPresent(Bool.self, forKey: .hasOnboarded) ?? false
        interests = try c.decodeIfPresent([String].self, forKey: .interests) ?? []
        tagWeights = try c.decodeIfPresent([String: Double].self, forKey: .tagWeights) ?? [:]
        lastOpenedAt = try c.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        focusProjectID = try c.decodeIfPresent(UUID.self, forKey: .focusProjectID)
    }

    public mutating func learn(tags: [String], signal: Double) {
        for tag in tags {
            let old = tagWeights[tag] ?? 0
            tagWeights[tag] = max(-1, min(1, old * 0.8 + signal * 0.4))
        }
    }
}

public enum ActivityKind: String, Codable, Sendable {
    case focusCompleted, stageChanged, release, buildSucceeded, buildFailed, storeStateChanged
    case revenueAnomaly, opportunityFound, questionAnswered, assumptionMade, projectAdded, stepCompleted
}

public struct ActivityEvent: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var date: Date
    public var kind: ActivityKind
    public var title: String
    public var projectID: UUID?

    public init(id: UUID = UUID(), date: Date, kind: ActivityKind, title: String, projectID: UUID? = nil) {
        self.id = id
        self.date = date
        self.kind = kind
        self.title = title
        self.projectID = projectID
    }
}

/// An App Store Connect app discovered during sync.
public struct StoreApp: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var bundleID: String
    public var sku: String?

    public init(id: String, name: String, bundleID: String, sku: String? = nil) {
        self.id = id
        self.name = name
        self.bundleID = bundleID
        self.sku = sku
    }
}

/// The whole local database. Encrypted at rest by the app layer.
public struct MomentumData: Codable, Sendable {
    public static let currentVersion = 1

    public var version: Int = MomentumData.currentVersion
    public var projects: [Project] = []
    public var opportunities: [Opportunity] = []
    public var revenue: [RevenueEntry] = []
    public var downloads: [DownloadEntry] = []
    public var metrics: [SubscriptionMetrics] = []
    public var questions: [Question] = []
    public var notices: [Notice] = []
    public var focusSessions: [FocusSession] = []
    public var activity: [ActivityEvent] = []
    public var energy: EnergyCheckIn?
    public var preferences = Preferences()
    public var profile = UserProfile()
    public var integrations: [IntegrationKind: IntegrationState] = [:]
    public var storeApps: [StoreApp] = []
    public var dismissedRepos: [String] = []
    public var lastWeeklyReviewDay: DayKey?
    public var lastAnomalyDay: DayKey?
    public var lastResearchAt: Date?
    public var fxRates: FXRates?
    /// App Store sales report days already fetched (so empty days aren't re-requested).
    public var fetchedReportDays: [DayKey] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? MomentumData.currentVersion
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
        opportunities = try c.decodeIfPresent([Opportunity].self, forKey: .opportunities) ?? []
        revenue = try c.decodeIfPresent([RevenueEntry].self, forKey: .revenue) ?? []
        downloads = try c.decodeIfPresent([DownloadEntry].self, forKey: .downloads) ?? []
        metrics = try c.decodeIfPresent([SubscriptionMetrics].self, forKey: .metrics) ?? []
        questions = try c.decodeIfPresent([Question].self, forKey: .questions) ?? []
        notices = try c.decodeIfPresent([Notice].self, forKey: .notices) ?? []
        focusSessions = try c.decodeIfPresent([FocusSession].self, forKey: .focusSessions) ?? []
        activity = try c.decodeIfPresent([ActivityEvent].self, forKey: .activity) ?? []
        energy = try c.decodeIfPresent(EnergyCheckIn.self, forKey: .energy)
        preferences = try c.decodeIfPresent(Preferences.self, forKey: .preferences) ?? Preferences()
        profile = try c.decodeIfPresent(UserProfile.self, forKey: .profile) ?? UserProfile()
        integrations = try c.decodeIfPresent([IntegrationKind: IntegrationState].self, forKey: .integrations) ?? [:]
        storeApps = try c.decodeIfPresent([StoreApp].self, forKey: .storeApps) ?? []
        dismissedRepos = try c.decodeIfPresent([String].self, forKey: .dismissedRepos) ?? []
        lastWeeklyReviewDay = try c.decodeIfPresent(DayKey.self, forKey: .lastWeeklyReviewDay)
        lastAnomalyDay = try c.decodeIfPresent(DayKey.self, forKey: .lastAnomalyDay)
        lastResearchAt = try c.decodeIfPresent(Date.self, forKey: .lastResearchAt)
        fxRates = try c.decodeIfPresent(FXRates.self, forKey: .fxRates)
        fetchedReportDays = try c.decodeIfPresent([DayKey].self, forKey: .fetchedReportDays) ?? []
    }

    // MARK: Lookup helpers

    public func project(_ id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    public func projectIndex(_ id: UUID?) -> Int? {
        guard let id else { return nil }
        return projects.firstIndex { $0.id == id }
    }

    public func opportunityIndex(_ id: UUID?) -> Int? {
        guard let id else { return nil }
        return opportunities.firstIndex { $0.id == id }
    }

    public func integration(_ kind: IntegrationKind) -> IntegrationState {
        integrations[kind] ?? IntegrationState()
    }

    public var activeProjects: [Project] { projects.filter { $0.stage.isActive } }

    public var pendingQuestions: [Question] {
        questions.filter(\.isPending).sorted { ($0.priority, $1.createdAt) > ($1.priority, $0.createdAt) }
    }

    public var visibleNotices: [Notice] {
        notices.filter { !$0.isDismissed }.sorted { $0.createdAt > $1.createdAt }
    }

    public func energyToday(now: Date) -> EnergyLevel {
        guard let energy, energy.day == DayKey(now) else { return .medium }
        return energy.level
    }

    // MARK: Mutation helpers

    public mutating func log(_ kind: ActivityKind, _ title: String, projectID: UUID? = nil, at date: Date) {
        activity.append(ActivityEvent(date: date, kind: kind, title: title, projectID: projectID))
        if activity.count > 1500 { activity.removeFirst(activity.count - 1500) }
    }

    public mutating func notify(_ kind: NoticeKind, _ text: String, questionID: UUID? = nil, at date: Date) {
        notices.append(Notice(kind: kind, text: text, questionID: questionID, createdAt: date))
        if notices.count > 200 { notices.removeFirst(notices.count - 200) }
    }

    /// Removes answered/expired questions and dismissed notices older than 30 days.
    public mutating func compact(now: Date) {
        let cutoff = now.addingTimeInterval(-30 * 86_400)
        questions.removeAll { !$0.isPending && ($0.resolvedAt ?? $0.createdAt) < cutoff }
        notices.removeAll { $0.isDismissed && $0.createdAt < cutoff }
        let revenueCutoff = DayKey(now.addingTimeInterval(-800 * 86_400))
        revenue.removeAll { $0.day < revenueCutoff }
        downloads.removeAll { $0.day < revenueCutoff }
    }
}
