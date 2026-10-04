import Foundation

public enum QuestionKind: String, Codable, Sendable {
    case energy
    case interests
    case projectStall
    case trackRepo
    case linkApp
    case researchPick
    case featureCheck
    case promoteOpportunity
    case revenueAnomaly
    case resubmit
    case nextActionPick
    case stepDone
    case keepActive
    case weeklyFocus
    case tomorrowPlan
    case welcomeBack
}

public struct AnswerOption: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var label: String

    public init(_ id: String, _ label: String) {
        self.id = id
        self.label = label
    }
}

public enum QuestionStatus: String, Codable, Sendable {
    case pending, answered, assumed, expired
}

/// A single direct, answerable question. Never open-ended.
public struct Question: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: QuestionKind
    public var prompt: String
    public var detail: String?
    public var options: [AnswerOption]
    /// The safe assumption applied if the question expires unanswered.
    public var defaultOptionID: String?
    /// Shown after the assumption is applied, e.g. "I assumed 'Recipe Radar' is paused."
    public var assumption: String?
    public var subjectID: UUID?
    public var context: [String: String]
    public var priority: Int
    public var dedupeKey: String
    public var createdAt: Date
    public var expiresAt: Date
    public var status: QuestionStatus
    public var answerID: String?
    public var resolvedAt: Date?
    public var shownAt: Date?

    public init(
        id: UUID = UUID(),
        kind: QuestionKind,
        prompt: String,
        detail: String? = nil,
        options: [AnswerOption],
        defaultOptionID: String? = nil,
        assumption: String? = nil,
        subjectID: UUID? = nil,
        context: [String: String] = [:],
        priority: Int = 50,
        dedupeKey: String,
        createdAt: Date,
        lifetimeHours: Double = 24
    ) {
        self.id = id
        self.kind = kind
        self.prompt = prompt
        self.detail = detail
        self.options = options
        self.defaultOptionID = defaultOptionID
        self.assumption = assumption
        self.subjectID = subjectID
        self.context = context
        self.priority = priority
        self.dedupeKey = dedupeKey
        self.createdAt = createdAt
        self.expiresAt = createdAt.addingTimeInterval(lifetimeHours * 3600)
        self.status = .pending
        self.answerID = nil
        self.resolvedAt = nil
        self.shownAt = nil
    }

    public var isPending: Bool { status == .pending }

    public func label(for optionID: String?) -> String? {
        options.first { $0.id == optionID }?.label
    }
}

public enum NoticeKind: String, Codable, Sendable {
    case assumption, info, alert, win
}

/// A calm, dismissible line on the Today screen ("I assumed …  Tap to change.").
public struct Notice: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: NoticeKind
    public var text: String
    public var questionID: UUID?
    public var createdAt: Date
    public var isDismissed: Bool

    public init(id: UUID = UUID(), kind: NoticeKind, text: String, questionID: UUID? = nil, createdAt: Date) {
        self.id = id
        self.kind = kind
        self.text = text
        self.questionID = questionID
        self.createdAt = createdAt
        self.isDismissed = false
    }
}
