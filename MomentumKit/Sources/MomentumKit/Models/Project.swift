import Foundation

public enum ProjectStage: String, Codable, CaseIterable, Sendable {
    case idea, prototype, mvp, beta, submitted, live, updating, paused, abandoned

    public var title: String {
        switch self {
        case .idea: "Idea"
        case .prototype: "Prototype"
        case .mvp: "MVP"
        case .beta: "Beta"
        case .submitted: "Submitted"
        case .live: "Live"
        case .updating: "Updating"
        case .paused: "Paused"
        case .abandoned: "Abandoned"
        }
    }

    /// Baseline progress toward "shipped" used for the progress ring.
    public var baseProgress: Double {
        switch self {
        case .idea: 0.05
        case .prototype: 0.25
        case .mvp: 0.5
        case .beta: 0.7
        case .submitted: 0.85
        case .live, .updating: 1.0
        case .paused, .abandoned: 0
        }
    }

    public var isActive: Bool { self != .paused && self != .abandoned }
}

public enum StageSource: String, Codable, Sendable {
    case inferred, user
}

public enum CIStatus: String, Codable, Sendable {
    case success, failure, running, cancelled
}

/// Normalised App Store version state (covers both `appStoreState` and `appVersionState`).
public enum StoreState: String, Codable, Sendable {
    case preparing, waitingForReview, inReview, pendingRelease, live, rejected, removed, unknown

    public init(appStoreConnectValue raw: String) {
        switch raw.uppercased() {
        case "READY_FOR_SALE", "READY_FOR_DISTRIBUTION": self = .live
        case "WAITING_FOR_REVIEW", "READY_FOR_REVIEW", "WAITING_FOR_EXPORT_COMPLIANCE": self = .waitingForReview
        case "IN_REVIEW", "PROCESSING_FOR_APP_STORE", "PROCESSING_FOR_DISTRIBUTION": self = .inReview
        case "PENDING_DEVELOPER_RELEASE", "PENDING_APPLE_RELEASE", "ACCEPTED", "PRE_ORDER_READY_FOR_SALE": self = .pendingRelease
        case "REJECTED", "METADATA_REJECTED", "INVALID_BINARY": self = .rejected
        case "DEVELOPER_REMOVED_FROM_SALE", "REMOVED_FROM_SALE", "DEVELOPER_REJECTED", "REPLACED_WITH_NEW_VERSION": self = .removed
        case "PREPARE_FOR_SUBMISSION": self = .preparing
        default: self = .unknown
        }
    }
}

public struct StoreVersion: Codable, Hashable, Sendable {
    public var version: String
    public var state: StoreState
    public var createdAt: Date?

    public init(version: String, state: StoreState, createdAt: Date?) {
        self.version = version
        self.state = state
        self.createdAt = createdAt
    }
}

public struct IssueRef: Codable, Hashable, Sendable {
    public var number: Int
    public var title: String
    public var isBug: Bool

    public init(number: Int, title: String, isBug: Bool) {
        self.number = number
        self.title = title
        self.isBug = isBug
    }
}

/// Everything Momentum observed about a project from connected tools.
public struct ProjectSignals: Codable, Hashable, Sendable {
    public var commitsLast7Days: Int = 0
    public var commitsLast30Days: Int = 0
    public var lastCommitAt: Date?
    public var openIssues: [IssueRef] = []
    public var ciStatus: CIStatus?
    public var ciUpdatedAt: Date?
    public var ciRunURL: String?
    public var latestReleaseTag: String?
    public var latestReleaseAt: Date?
    public var latestBuildUploadedAt: Date?
    public var liveVersion: String?
    public var currentStoreVersion: StoreVersion?
    public var storeStateChangedAt: Date?

    public init() {}

    /// The most recent moment anything happened in a connected tool.
    public var lastActivityAt: Date? {
        [lastCommitAt, ciUpdatedAt, latestReleaseAt, latestBuildUploadedAt, storeStateChangedAt]
            .compactMap { $0 }
            .max()
    }
}

public struct ProjectLinks: Codable, Hashable, Sendable {
    public var githubRepo: String?
    public var appStoreAppID: String?
    public var bundleID: String?
    public var appName: String?

    public init(githubRepo: String? = nil, appStoreAppID: String? = nil, bundleID: String? = nil, appName: String? = nil) {
        self.githubRepo = githubRepo
        self.appStoreAppID = appStoreAppID
        self.bundleID = bundleID
        self.appName = appName
    }
}

public struct Project: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var symbol: String
    public var stage: ProjectStage
    public var stageSource: StageSource
    public var stageChangedAt: Date
    public var createdAt: Date
    public var links: ProjectLinks
    public var signals: ProjectSignals
    /// Manual "I touched this" marker (focus sessions, answers) that counts as activity.
    public var lastTouchedAt: Date?
    public var steps: [MicroStep]
    public var snoozedUntil: Date?
    public var isStuck: Bool
    /// The activity date we last asked a stall question about, so we ask once per stall.
    public var stallAskedForActivityAt: Date?
    /// When AI last refreshed this project's steps (rate-limits AI calls).
    public var aiStepsAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        symbol: String? = nil,
        stage: ProjectStage = .idea,
        stageSource: StageSource = .inferred,
        createdAt: Date = Date(),
        links: ProjectLinks = ProjectLinks(),
        signals: ProjectSignals = ProjectSignals(),
        steps: [MicroStep] = []
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol ?? Project.symbol(for: name)
        self.stage = stage
        self.stageSource = stageSource
        self.stageChangedAt = createdAt
        self.createdAt = createdAt
        self.links = links
        self.signals = signals
        self.lastTouchedAt = nil
        self.steps = steps
        self.snoozedUntil = nil
        self.isStuck = false
        self.stallAskedForActivityAt = nil
        self.aiStepsAt = nil
    }

    public var lastActivityAt: Date? {
        [signals.lastActivityAt, lastTouchedAt].compactMap { $0 }.max()
    }

    public func daysSinceActivity(now: Date) -> Int {
        Int(now.days(since: lastActivityAt ?? createdAt).rounded(.down))
    }

    public var progress: Double {
        guard stage.isActive else { return 0 }
        let done = steps.filter { $0.isDone }.count
        let bonus = steps.isEmpty ? 0 : Double(done) / Double(steps.count) * 0.1
        return min(1, stage.baseProgress + bonus)
    }

    public var openSteps: [MicroStep] { steps.filter { !$0.isDone } }

    /// True when AI could usefully replace generic template steps.
    public func wantsAISteps(now: Date) -> Bool {
        guard stage.isActive else { return false }
        if let at = aiStepsAt, now.days(since: at) < 1 { return false }
        let open = openSteps
        return open.count < 2 || open.allSatisfy { $0.source == .template }
    }

    /// Replaces open template steps with AI-suggested ones (signal and user steps stay first).
    public mutating func applyAISteps(_ fresh: [MicroStep], now: Date) {
        guard !fresh.isEmpty else { return }
        let keep = openSteps.filter { $0.source == .signal || $0.source == .user }
        steps = keep + fresh + steps.filter(\.isDone)
        aiStepsAt = now
    }

    public func isSnoozed(now: Date) -> Bool { (snoozedUntil ?? .distantPast) > now }

    /// A stable SF Symbol guess from the project name.
    public static func symbol(for name: String) -> String {
        let lower = name.lowercased()
        let table: [(String, String)] = [
            ("habit", "checkmark.circle"), ("focus", "scope"), ("timer", "timer"), ("recipe", "fork.knife"),
            ("food", "fork.knife"), ("fit", "figure.run"), ("health", "heart"), ("money", "dollarsign.circle"),
            ("budget", "dollarsign.circle"), ("finance", "chart.line.uptrend.xyaxis"), ("photo", "camera"),
            ("music", "music.note"), ("sleep", "moon"), ("journal", "book"), ("note", "note.text"),
            ("task", "checklist"), ("todo", "checklist"), ("weather", "cloud.sun"), ("travel", "airplane"),
            ("game", "gamecontroller"), ("chat", "bubble.left.and.bubble.right"), ("map", "map"),
            ("learn", "graduationcap"), ("event", "calendar"), ("kid", "figure.and.child.holdinghands")
        ]
        return table.first { lower.contains($0.0) }?.1 ?? "app.dashed"
    }
}

/// A tiny, concrete step (5–25 minutes).
public struct MicroStep: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var minutes: Int
    public var energy: EnergyLevel
    public var source: StepSource
    public var isDone: Bool
    public var createdAt: Date
    public var completedAt: Date?

    public init(id: UUID = UUID(), title: String, minutes: Int = 15, energy: EnergyLevel = .medium,
                source: StepSource = .template, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.minutes = minutes
        self.energy = energy
        self.source = source
        self.isDone = false
        self.createdAt = createdAt
        self.completedAt = nil
    }
}

public enum StepSource: String, Codable, Sendable {
    case template, signal, ai, user
}
