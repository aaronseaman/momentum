import Foundation

/// Infers a project's stage from connected-tool signals. Never asks the user.
public enum StageInference {
    /// Returns the inferred stage, or `nil` when signals are too thin to say anything.
    public static func infer(_ project: Project) -> ProjectStage? {
        let s = project.signals

        if let version = s.currentStoreVersion {
            switch version.state {
            case .waitingForReview, .inReview, .pendingRelease:
                return .submitted
            case .live:
                return .live
            case .rejected:
                return s.liveVersion != nil ? .updating : .submitted
            case .preparing:
                // A new version is being prepared on top of a live one.
                return s.liveVersion != nil ? .updating : (s.latestBuildUploadedAt != nil ? .beta : nil)
            case .removed, .unknown:
                break
            }
        }

        if s.liveVersion != nil {
            // Live in the store and actively committing => working on an update.
            return s.commitsLast7Days >= 3 ? .updating : .live
        }

        if s.latestBuildUploadedAt != nil { return .beta }

        if s.latestReleaseTag != nil {
            let tag = s.latestReleaseTag!.lowercased()
            if tag.contains("beta") || tag.contains("rc") { return .beta }
            return s.commitsLast30Days > 0 ? .mvp : .beta
        }

        switch s.commitsLast30Days {
        case 0:
            return s.lastCommitAt == nil ? nil : .prototype
        case 1..<25:
            return .prototype
        default:
            return .mvp
        }
    }

    /// Applies inference, respecting user decisions. A stage the user chose only yields to
    /// genuinely new evidence: store state (authoritative), forward progress, or fresh
    /// activity on a project they had paused.
    @discardableResult
    public static func apply(to project: inout Project, now: Date) -> ProjectStage? {
        guard let inferred = infer(project), inferred != project.stage else { return nil }

        if project.stageSource == .user {
            let decidedAt = project.stageChangedAt
            let storeChanged = (project.signals.storeStateChangedAt ?? .distantPast) > decidedAt
            let newCommits = (project.signals.lastCommitAt ?? .distantPast) > decidedAt
            if project.stage.isActive {
                let isStoreStage = [.submitted, .live, .updating].contains(inferred)
                let movesForward = inferred.order > project.stage.order
                guard (isStoreStage && storeChanged) || (movesForward && (newCommits || storeChanged)) else { return nil }
            } else {
                guard newCommits || storeChanged else { return nil }
            }
        }

        let old = project.stage
        project.stage = inferred
        project.stageSource = .inferred
        project.stageChangedAt = now
        return old
    }
}

extension ProjectStage {
    /// Lifecycle order used to decide whether inference is "forward progress".
    var order: Int {
        switch self {
        case .idea: 0
        case .prototype: 1
        case .mvp: 2
        case .beta: 3
        case .submitted: 4
        case .live: 5
        case .updating: 6
        case .paused, .abandoned: -1
        }
    }
}
