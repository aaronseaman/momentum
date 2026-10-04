import Foundation

/// Side effects an answer asks the app layer to perform.
public enum AnswerEffect: Hashable, Sendable {
    case showMoney
    case showRadar(UUID?)
    case showProject(UUID)
    case planTomorrow
    case startFocus
}

/// The minimal-input core: what to ask, when, and what an answer (or silence) means.
public enum QuestionEngine {

    // MARK: Queueing

    /// Adds a question unless an equivalent one is pending or was resolved within `cooldownDays`.
    @discardableResult
    public static func enqueue(_ question: Question, into data: inout MomentumData, cooldownDays: Double = 0) -> Bool {
        let duplicate = data.questions.contains { existing in
            guard existing.dedupeKey == question.dedupeKey else { return false }
            if existing.isPending { return true }
            guard cooldownDays > 0, let resolved = existing.resolvedAt else { return false }
            return question.createdAt.days(since: resolved) < cooldownDays
        }
        guard !duplicate else { return false }
        data.questions.append(question)
        return true
    }

    public static func answeredToday(_ data: MomentumData, now: Date) -> Int {
        let today = DayKey(now)
        return data.questions.filter { $0.status == .answered && $0.resolvedAt.map { DayKey($0) == today } == true }.count
    }

    /// The one question Today shows, respecting the daily budget. Urgent questions bypass it.
    public static func current(_ data: MomentumData, now: Date) -> Question? {
        let pending = data.pendingQuestions.filter { $0.expiresAt > now }
        if answeredToday(data, now: now) >= data.preferences.maxQuestionsPerDay {
            return pending.first { $0.priority >= 85 }
        }
        return pending.first
    }

    public static func remainingCount(_ data: MomentumData, now: Date) -> Int {
        data.pendingQuestions.filter { $0.expiresAt > now }.count
    }

    // MARK: Answering

    @discardableResult
    public static func answer(_ questionID: UUID, optionID: String, data: inout MomentumData, now: Date) -> [AnswerEffect] {
        guard let index = data.questions.firstIndex(where: { $0.id == questionID }),
              data.questions[index].options.contains(where: { $0.id == optionID }) else { return [] }
        let question = data.questions[index]
        data.questions[index].status = .answered
        data.questions[index].answerID = optionID
        data.questions[index].resolvedAt = now
        // Answering again ("tap to change") clears the old assumption notice.
        for i in data.notices.indices where data.notices[i].questionID == questionID {
            data.notices[i].isDismissed = true
        }
        data.log(.questionAnswered, "\(question.prompt) → \(question.label(for: optionID) ?? optionID)", projectID: question.subjectID, at: now)
        return apply(question, optionID: optionID, assumed: false, data: &data, now: now)
    }

    /// Re-opens a resolved question so the user can change an assumption with one tap.
    public static func reopen(_ questionID: UUID, data: inout MomentumData, now: Date) {
        guard let index = data.questions.firstIndex(where: { $0.id == questionID }) else { return }
        data.questions[index].status = .pending
        data.questions[index].priority = 95
        data.questions[index].expiresAt = now.addingTimeInterval(24 * 3600)
        data.questions[index].defaultOptionID = nil
    }

    /// Applies safe assumptions to expired questions and announces them.
    public static func expire(_ data: inout MomentumData, now: Date) {
        for index in data.questions.indices where data.questions[index].isPending && data.questions[index].expiresAt <= now {
            let question = data.questions[index]
            data.questions[index].resolvedAt = now
            guard let fallback = question.defaultOptionID else {
                data.questions[index].status = .expired
                continue
            }
            data.questions[index].status = .assumed
            data.questions[index].answerID = fallback
            _ = apply(question, optionID: fallback, assumed: true, data: &data, now: now)
            if let text = question.assumption {
                data.notify(.assumption, text, questionID: question.id, at: now)
                data.log(.assumptionMade, text, projectID: question.subjectID, at: now)
            }
        }
    }

    // MARK: Effects

    static func apply(_ q: Question, optionID: String, assumed: Bool, data: inout MomentumData, now: Date) -> [AnswerEffect] {
        switch q.kind {
        case .energy:
            if let level = EnergyLevel(rawValue: optionID) {
                data.energy = EnergyCheckIn(day: DayKey(now), level: level, wasAssumed: assumed)
            }

        case .interests:
            guard let tag = q.context["tag"] else { break }
            if optionID == "yes" {
                if !data.profile.interests.contains(tag) { data.profile.interests.append(tag) }
                data.profile.learn(tags: [tag], signal: 1)
            } else {
                data.profile.learn(tags: [tag], signal: -1)
            }

        case .projectStall, .keepActive:
            guard let i = data.projectIndex(q.subjectID) else { break }
            switch optionID {
            case "active", "yes":
                data.projects[i].lastTouchedAt = now
                if !data.projects[i].stage.isActive { setStage(&data, i, .prototype, now: now) }
            case "paused", "pause":
                setStage(&data, i, .paused, now: now)
            case "abandoned", "archive":
                setStage(&data, i, .abandoned, now: now)
            case "stuck":
                data.projects[i].isStuck = true
                data.projects[i].lastTouchedAt = now
                let fresh = Planner.unstickSteps(projectName: data.projects[i].name, now: now)
                data.projects[i].steps.insert(contentsOf: fresh, at: 0)
                return [.showProject(data.projects[i].id)]
            default: break
            }

        case .trackRepo:
            guard let repo = q.context["repo"] else { break }
            if optionID == "yes" {
                if !data.projects.contains(where: { $0.links.githubRepo == repo }) {
                    let name = q.context["name"] ?? repo.components(separatedBy: "/").last ?? repo
                    var project = Project(name: Naming.displayName(fromRepo: name), createdAt: now, links: ProjectLinks(githubRepo: repo))
                    Planner.restock(&project, now: now)
                    data.projects.append(project)
                    data.log(.projectAdded, "Started tracking \(project.name)", projectID: project.id, at: now)
                }
            } else if !data.dismissedRepos.contains(repo) {
                data.dismissedRepos.append(repo)
                data.projects.removeAll { $0.links.githubRepo == repo && $0.signals.liveVersion == nil }
            }

        case .linkApp:
            guard let appID = q.context["appID"] else { break }
            if optionID == "yes", let i = data.projectIndex(q.subjectID) {
                data.projects[i].links.appStoreAppID = appID
                data.projects[i].links.appName = q.context["appName"]
                // Drop the placeholder project we may have created for the app.
                data.projects.removeAll { $0.id != q.subjectID && $0.links.appStoreAppID == appID && $0.links.githubRepo == nil }
            } else if optionID == "no", !data.projects.contains(where: { $0.links.appStoreAppID == appID }) {
                let name = q.context["appName"] ?? "App \(appID)"
                var project = Project(name: name, createdAt: now, links: ProjectLinks(appStoreAppID: appID, bundleID: q.context["bundleID"], appName: name))
                Planner.restock(&project, now: now)
                data.projects.append(project)
            }

        case .researchPick:
            guard let i = data.opportunityIndex(UUID(uuidString: optionID)) else { break }
            data.opportunities[i].status = .starred
            data.opportunities[i].researchedAt = nil
            data.profile.learn(tags: data.opportunities[i].tags, signal: 1)
            return [.showRadar(data.opportunities[i].id)]

        case .featureCheck:
            guard let i = data.opportunityIndex(q.subjectID),
                  let feature = q.context["feature"].flatMap(DifficultyFeature.init(rawValue:)),
                  let answer = FeatureAnswer(rawValue: optionID) else { break }
            data.opportunities[i].features[feature] = answer
            Scoring.rescore(&data.opportunities[i], profile: data.profile, shippedApps: shippedApps(data), now: now)

        case .promoteOpportunity:
            guard let i = data.opportunityIndex(q.subjectID) else { break }
            if optionID == "yes" {
                return [.showProject(promote(&data, opportunityIndex: i, now: now))]
            } else {
                data.profile.learn(tags: data.opportunities[i].tags, signal: -0.3)
            }

        case .revenueAnomaly:
            if optionID == "yes" {
                if let i = data.projectIndex(q.subjectID) {
                    let step = MicroStep(title: "Look into the \(q.context["direction"] ?? "change") in \(data.projects[i].name) revenue", minutes: 10, energy: .low, source: .signal, createdAt: now)
                    data.projects[i].steps.insert(step, at: 0)
                }
                return [.showMoney]
            }

        case .resubmit:
            guard let i = data.projectIndex(q.subjectID) else { break }
            switch optionID {
            case "yes":
                let step = MicroStep(title: "Fix the review issue and resubmit \(data.projects[i].name)", minutes: 25, energy: .medium, source: .user, createdAt: now)
                data.projects[i].steps.insert(step, at: 0)
                data.profile.focusProjectID = data.projects[i].id
            case "later":
                data.projects[i].snoozedUntil = now.addingTimeInterval(24 * 3600)
            default: break
            }

        case .nextActionPick:
            guard let i = data.projectIndex(q.subjectID), let stepID = UUID(uuidString: optionID),
                  let s = data.projects[i].steps.firstIndex(where: { $0.id == stepID }) else { break }
            let step = data.projects[i].steps.remove(at: s)
            data.projects[i].steps.insert(step, at: 0)
            if !assumed { data.profile.focusProjectID = data.projects[i].id }

        case .stepDone:
            guard let i = data.projectIndex(q.subjectID),
                  let stepID = q.context["stepID"].flatMap(UUID.init(uuidString:)) else { break }
            switch optionID {
            case "done":
                completeStep(&data, projectIndex: i, stepID: stepID, now: now)
            case "blocked":
                data.projects[i].isStuck = true
                data.projects[i].steps.insert(contentsOf: Planner.unstickSteps(projectName: data.projects[i].name, now: now), at: 0)
            default: break
            }

        case .weeklyFocus:
            data.profile.focusProjectID = UUID(uuidString: optionID)

        case .tomorrowPlan:
            if optionID == "yes" { return [.planTomorrow] }

        case .welcomeBack:
            if optionID == "fresh" {
                for i in data.projects.indices {
                    data.projects[i].isStuck = false
                    data.projects[i].steps.removeAll { !$0.isDone && $0.source == .template }
                    Planner.restock(&data.projects[i], now: now)
                }
            }
        }
        return []
    }

    // MARK: Shared mutations

    public static func setStage(_ data: inout MomentumData, _ index: Int, _ stage: ProjectStage, now: Date) {
        let old = data.projects[index].stage
        data.projects[index].stage = stage
        data.projects[index].stageSource = .user
        data.projects[index].stageChangedAt = now
        if old != stage {
            data.log(.stageChanged, "\(data.projects[index].name): \(old.title) → \(stage.title)", projectID: data.projects[index].id, at: now)
        }
        Planner.restock(&data.projects[index], now: now)
    }

    public static func completeStep(_ data: inout MomentumData, projectIndex i: Int, stepID: UUID, now: Date) {
        guard let s = data.projects[i].steps.firstIndex(where: { $0.id == stepID }), !data.projects[i].steps[s].isDone else { return }
        data.projects[i].steps[s].isDone = true
        data.projects[i].steps[s].completedAt = now
        data.projects[i].lastTouchedAt = now
        // Finishing anything means they're moving again.
        data.projects[i].isStuck = false
        data.log(.stepCompleted, data.projects[i].steps[s].title, projectID: data.projects[i].id, at: now)
        Planner.restock(&data.projects[i], now: now)
    }

    /// Turns an opportunity into an idea-stage project. Returns the new project's ID.
    @discardableResult
    public static func promote(_ data: inout MomentumData, opportunityIndex i: Int, now: Date) -> UUID {
        data.opportunities[i].status = .promoted
        data.profile.learn(tags: data.opportunities[i].tags, signal: 1)
        var project = Project(name: data.opportunities[i].title, createdAt: now)
        Planner.restock(&project, now: now)
        data.projects.append(project)
        data.log(.projectAdded, "New idea: \(project.name)", projectID: project.id, at: now)
        return project.id
    }

    static func shippedApps(_ data: MomentumData) -> Int {
        data.projects.filter { $0.signals.liveVersion != nil || $0.stage == .live || $0.stage == .updating }.count
    }
}

/// Small naming helpers shared by reducers.
public enum Naming {
    /// "focus-fox-ios" → "Focus Fox"
    public static func displayName(fromRepo name: String) -> String {
        let noise: Set<String> = ["ios", "app", "macos", "swift", "swiftui", "mobile", "client"]
        let words = name.replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .flatMap { splitCamel(String($0)) }
            .filter { !noise.contains($0.lowercased()) }
        let joined = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return joined.isEmpty ? name : joined
    }

    static func splitCamel(_ word: String) -> [String] {
        var parts: [String] = []
        var current = ""
        for char in word {
            if char.isUppercase, !current.isEmpty, current.last?.isLowercase == true {
                parts.append(current)
                current = ""
            }
            current.append(char)
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// Lowercased alphanumerics for fuzzy matching ("Focus Fox" == "focusfox-ios").
    public static func normalized(_ name: String) -> String {
        let noise = ["ios", "app", "macos", "swiftui", "swift"]
        var lower = name.lowercased().filter { $0.isLetter || $0.isNumber }
        for word in noise where lower.hasSuffix(word) && lower.count > word.count + 2 {
            lower.removeLast(word.count)
        }
        return lower
    }
}
