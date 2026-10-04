import Foundation

public enum EnergyLevel: String, Codable, CaseIterable, Sendable {
    case low, medium, high

    public var title: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    /// The longest step that feels doable at this energy level.
    public var comfortableMinutes: Int {
        switch self {
        case .low: 10
        case .medium: 25
        case .high: 50
        }
    }

    var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }

    public func canHandle(_ required: EnergyLevel) -> Bool { required.rank <= rank }
}

public struct EnergyCheckIn: Codable, Hashable, Sendable {
    public var day: DayKey
    public var level: EnergyLevel
    public var wasAssumed: Bool

    public init(day: DayKey, level: EnergyLevel, wasAssumed: Bool = false) {
        self.day = day
        self.level = level
        self.wasAssumed = wasAssumed
    }
}

public struct FocusSession: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public var plannedMinutes: Int
    public var actualMinutes: Int
    public var projectID: UUID?
    public var stepID: UUID?
    public var title: String
    public var completed: Bool

    public init(id: UUID = UUID(), startedAt: Date, plannedMinutes: Int, actualMinutes: Int,
                projectID: UUID?, stepID: UUID?, title: String, completed: Bool) {
        self.id = id
        self.startedAt = startedAt
        self.plannedMinutes = plannedMinutes
        self.actualMinutes = actualMinutes
        self.projectID = projectID
        self.stepID = stepID
        self.title = title
        self.completed = completed
    }
}

/// The single thing to do next, resolved from projects, signals and energy.
public struct NextAction: Hashable, Sendable {
    public var title: String
    public var minutes: Int
    public var projectID: UUID?
    public var projectName: String?
    public var stepID: UUID?
    public var reason: String
    /// The smallest possible first move, used by "I'm overwhelmed".
    public var tinyStep: String

    public init(title: String, minutes: Int, projectID: UUID?, projectName: String?, stepID: UUID?, reason: String, tinyStep: String) {
        self.title = title
        self.minutes = minutes
        self.projectID = projectID
        self.projectName = projectName
        self.stepID = stepID
        self.reason = reason
        self.tinyStep = tinyStep
    }
}
