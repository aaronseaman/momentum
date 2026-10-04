import Foundation

/// Something worth a tap on the shoulder right now.
public struct AlertEvent: Hashable, Sendable {
    public enum Kind: String, Sendable { case revenue, build, store, trend, review }
    public var kind: Kind
    public var title: String
    public var body: String
    public var questionID: UUID?

    public init(kind: Kind, title: String, body: String, questionID: UUID? = nil) {
        self.kind = kind
        self.title = title
        self.body = body
        self.questionID = questionID
    }
}

/// The background brain. `tick` is pure: same data + time in, same data out.
public enum Engine {

    /// Runs every inference pass. Call after each sync, on launch, and on a timer.
    @discardableResult
    public static func tick(_ data: inout MomentumData, now: Date, calendar: Calendar = .current) -> [AlertEvent] {
        var alerts: [AlertEvent] = []
        QuestionEngine.expire(&data, now: now)

        for i in data.projects.indices {
            if let old = StageInference.apply(to: &data.projects[i], now: now) {
                data.log(.stageChanged, "\(data.projects[i].name): \(old.title) → \(data.projects[i].stage.title)", projectID: data.projects[i].id, at: now)
            }
            Planner.restock(&data.projects[i], now: now)
        }

        askAboutStalls(&data, now: now)
        askEnergy(&data, now: now, calendar: calendar)
        alerts += checkRevenue(&data, now: now)
        askResearch(&data, now: now)
        askEvening(&data, now: now, calendar: calendar)
        askWeekly(&data, now: now, calendar: calendar)
        askNextActionPick(&data, now: now)
        data.compact(now: now)
        return alerts
    }

    /// Call when the app comes to the foreground. Welcomes people back without guilt.
    public static func appOpened(_ data: inout MomentumData, now: Date) {
        if let last = data.profile.lastOpenedAt, now.days(since: last) >= 4, !data.projects.isEmpty {
            QuestionEngine.enqueue(Question(
                kind: .welcomeBack,
                prompt: "Welcome back. Want to pick up where you left off?",
                options: [AnswerOption("yes", "Yes"), AnswerOption("fresh", "Start fresh")],
                defaultOptionID: "yes",
                priority: 90,
                dedupeKey: "welcome-\(DayKey(now))",
                createdAt: now,
                lifetimeHours: 12
            ), into: &data)
        }
        data.profile.lastOpenedAt = now
    }

    // MARK: Projects

    static func askAboutStalls(_ data: inout MomentumData, now: Date) {
        for i in data.projects.indices {
            let project = data.projects[i]
            guard project.stage.isActive, !project.isSnoozed(now: now),
                  project.daysSinceActivity(now: now) >= data.preferences.stallDays else { continue }
            let marker = project.lastActivityAt ?? project.createdAt
            if let asked = project.stallAskedForActivityAt, abs(asked.timeIntervalSince(marker)) < 1 { continue }
            data.projects[i].stallAskedForActivityAt = marker
            QuestionEngine.enqueue(Question(
                kind: .projectStall,
                prompt: "“\(project.name)” hasn't had activity in \(project.daysSinceActivity(now: now)) days. Is it:",
                options: [AnswerOption("active", "Active but slow"), AnswerOption("paused", "Paused"),
                          AnswerOption("abandoned", "Abandoned"), AnswerOption("stuck", "I'm stuck")],
                defaultOptionID: "paused",
                assumption: "I assumed “\(project.name)” is paused. Tap to change.",
                subjectID: project.id,
                priority: 70,
                dedupeKey: "stall-\(project.id)",
                createdAt: now,
                lifetimeHours: 36
            ), into: &data)
        }
    }

    static func askNextActionPick(_ data: inout MomentumData, now: Date) {
        guard let focusID = data.profile.focusProjectID, let project = data.project(focusID), project.stage.isActive else { return }
        let options = project.openSteps.prefix(3)
        guard options.count >= 3 else { return }
        QuestionEngine.enqueue(Question(
            kind: .nextActionPick,
            prompt: "Next for “\(project.name)”:",
            options: options.map { AnswerOption($0.id.uuidString, $0.title) } + [AnswerOption("later", "Later")],
            defaultOptionID: options.first?.id.uuidString,
            subjectID: project.id,
            priority: 35,
            dedupeKey: "pick-\(project.id)",
            createdAt: now,
            lifetimeHours: 20
        ), into: &data, cooldownDays: 3)
    }

    // MARK: Daily rhythm

    static func askEnergy(_ data: inout MomentumData, now: Date, calendar: Calendar) {
        let hour = calendar.component(.hour, from: now)
        guard hour >= 5, hour < 20, data.energy?.day != DayKey(now) else { return }
        let endOfDay = calendar.startOfDay(for: now).addingTimeInterval(24 * 3600 - 60)
        QuestionEngine.enqueue(Question(
            kind: .energy,
            prompt: "Your energy today?",
            options: EnergyLevel.allCases.map { AnswerOption($0.rawValue, $0.title) },
            defaultOptionID: EnergyLevel.medium.rawValue,
            priority: 60,
            dedupeKey: "energy-\(DayKey(now))",
            createdAt: now,
            lifetimeHours: max(1, endOfDay.timeIntervalSince(now) / 3600)
        ), into: &data)
    }

    static func askEvening(_ data: inout MomentumData, now: Date, calendar: Calendar) {
        let prefs = data.preferences
        guard prefs.eveningSummary, calendar.component(.hour, from: now) >= prefs.eveningTime.hour,
              calendar.component(.hour, from: now) < 23, !data.activeProjects.isEmpty else { return }
        QuestionEngine.enqueue(Question(
            kind: .tomorrowPlan,
            prompt: "Want tomorrow's plan?",
            options: [AnswerOption("yes", "Yes"), AnswerOption("no", "No")],
            priority: 40,
            dedupeKey: "plan-\(DayKey(now))",
            createdAt: now,
            lifetimeHours: 5
        ), into: &data)
    }

    static func askWeekly(_ data: inout MomentumData, now: Date, calendar: Calendar) {
        let prefs = data.preferences
        let today = DayKey(now)
        guard prefs.weeklyReview, calendar.component(.weekday, from: now) == prefs.weeklyReviewWeekday,
              calendar.component(.hour, from: now) >= prefs.weeklyReviewTime.hour,
              data.lastWeeklyReviewDay != today else { return }
        data.lastWeeklyReviewDay = today

        let active = data.activeProjects
        if let quiet = active.max(by: { $0.daysSinceActivity(now: now) < $1.daysSinceActivity(now: now) }),
           quiet.daysSinceActivity(now: now) >= 5 {
            QuestionEngine.enqueue(Question(
                kind: .keepActive,
                prompt: "Do you want to keep “\(quiet.name)” active?",
                options: [AnswerOption("yes", "Yes"), AnswerOption("pause", "Pause"), AnswerOption("archive", "Archive")],
                defaultOptionID: "yes",
                subjectID: quiet.id,
                priority: 55,
                dedupeKey: "keep-\(quiet.id)-\(today)",
                createdAt: now,
                lifetimeHours: 48
            ), into: &data)
        }

        let ranked = active.sorted { Planner.priority(of: $0, data: data, now: now) > Planner.priority(of: $1, data: data, now: now) }
        if ranked.count >= 2 {
            QuestionEngine.enqueue(Question(
                kind: .weeklyFocus,
                prompt: "Which project gets your focus this week?",
                options: ranked.prefix(3).map { AnswerOption($0.id.uuidString, $0.name) },
                defaultOptionID: ranked[0].id.uuidString,
                priority: 54,
                dedupeKey: "focus-\(today)",
                createdAt: now,
                lifetimeHours: 48
            ), into: &data)
        }

        if let top = data.opportunities.filter({ $0.isVisible && !$0.tags.isEmpty }).max(by: { ($0.opportunityScore ?? 0) < ($1.opportunityScore ?? 0) }),
           let tag = top.tags.first {
            QuestionEngine.enqueue(Question(
                kind: .interests,
                prompt: "Want more \(tag) app ideas on your Radar?",
                options: [AnswerOption("yes", "Yes"), AnswerOption("no", "No")],
                context: ["tag": tag],
                priority: 53,
                dedupeKey: "interest-\(tag)",
                createdAt: now,
                lifetimeHours: 48
            ), into: &data, cooldownDays: 30)
        }
    }

    // MARK: Radar

    static func askResearch(_ data: inout MomentumData, now: Date) {
        let candidates = data.opportunities
            .filter { $0.status == .candidate && $0.researchedAt == nil }
            .sorted { Scoring.fit(tags: $0.tags, profile: data.profile) > Scoring.fit(tags: $1.tags, profile: data.profile) }
        if candidates.count >= 2 {
            QuestionEngine.enqueue(Question(
                kind: .researchPick,
                prompt: "Which opportunity should I research next?",
                options: candidates.prefix(3).map { AnswerOption($0.id.uuidString, $0.title) } + [AnswerOption("skip", "Skip")],
                priority: 30,
                dedupeKey: "research-\(DayKey(now))",
                createdAt: now,
                lifetimeHours: 20
            ), into: &data)
        }

        // Ask about the most uncertain, highest-weight feature on promising ideas only.
        for opp in data.opportunities where opp.isVisible && (opp.opportunityScore ?? 0) >= 60 && opp.researchedAt != nil {
            let unknown = DifficultyFeature.allCases
                .filter { opp.features[$0] == nil && [.realtimeVideo, .ai, .cloudSync, .payments].contains($0) }
                .max { $0.weight < $1.weight }
            if let feature = unknown {
                let added = QuestionEngine.enqueue(Question(
                    kind: .featureCheck,
                    prompt: "Would “\(opp.title)” \(feature.question)?",
                    options: [AnswerOption("yes", "Yes"), AnswerOption("no", "No"), AnswerOption("unsure", "Unsure")],
                    defaultOptionID: "unsure",
                    subjectID: opp.id,
                    context: ["feature": feature.rawValue],
                    priority: 25,
                    dedupeKey: "feature-\(opp.id)-\(feature.rawValue)",
                    createdAt: now,
                    lifetimeHours: 48
                ), into: &data)
                if added { break }
            }
        }

        if let star = data.opportunities.first(where: { $0.status == .starred && ($0.opportunityScore ?? 0) >= 70 && $0.researchedAt != nil }) {
            QuestionEngine.enqueue(Question(
                kind: .promoteOpportunity,
                prompt: "“\(star.title)” scores \(star.opportunityScore ?? 0). Turn it into a project?",
                options: [AnswerOption("yes", "Yes"), AnswerOption("no", "Not now")],
                subjectID: star.id,
                priority: 45,
                dedupeKey: "promote-\(star.id)",
                createdAt: now,
                lifetimeHours: 72
            ), into: &data, cooldownDays: 14)
        }
    }

    // MARK: Money

    static func checkRevenue(_ data: inout MomentumData, now: Date) -> [AlertEvent] {
        let yesterday = DayKey(now).adding(days: -1, timeZone: RevenueAnalytics.utc)
        guard data.lastAnomalyDay != yesterday, let anomaly = RevenueAnalytics.anomaly(data.revenue, on: yesterday) else { return [] }
        data.lastAnomalyDay = yesterday
        let investigation = Investigation.explain(anomaly, data: data, now: now)
        let verb = anomaly.direction == .drop ? "dropped" : "jumped"
        let pct = Int(abs(anomaly.percentChange).rounded())
        data.log(.revenueAnomaly, "Revenue \(verb) \(pct)% on \(yesterday)", projectID: investigation.projectID, at: now)

        let question: Question
        if let rejected = investigation.rejectedProject {
            question = Question(
                kind: .resubmit,
                prompt: "Revenue \(verb) because \(rejected.name) \(rejected.signals.currentStoreVersion?.version ?? "") failed review. Resubmit?",
                options: [AnswerOption("yes", "Yes"), AnswerOption("no", "No"), AnswerOption("later", "Later")],
                subjectID: rejected.id,
                priority: 88,
                dedupeKey: "resubmit-\(rejected.id)-\(yesterday)",
                createdAt: now,
                lifetimeHours: 24
            )
        } else {
            question = Question(
                kind: .revenueAnomaly,
                prompt: "Revenue \(verb) \(pct)% yesterday. Want to see why?",
                detail: investigation.cause,
                options: [AnswerOption("yes", "Yes"), AnswerOption("no", "No")],
                subjectID: investigation.projectID,
                context: ["direction": anomaly.direction == .drop ? "drop" : "jump", "day": yesterday.rawValue],
                priority: 86,
                dedupeKey: "anomaly-\(yesterday)",
                createdAt: now,
                lifetimeHours: 24
            )
        }
        QuestionEngine.enqueue(question, into: &data)
        return [AlertEvent(kind: .revenue, title: "Revenue \(verb) \(pct)%", body: investigation.cause ?? question.prompt, questionID: question.id)]
    }
}

/// Looks for the likely cause of a revenue anomaly in data Momentum already has.
public enum Investigation {
    public struct Result: Sendable {
        public var cause: String?
        public var projectID: UUID?
        public var rejectedProject: Project?
    }

    public static func explain(_ anomaly: RevenueAnomaly, data: MomentumData, now: Date) -> Result {
        let utc = RevenueAnalytics.utc
        var causes: [String] = []
        var result = Result()

        // Which project moved the most?
        let before = anomaly.day.adding(days: -7, timeZone: utc)
        let deltas = data.projects.map { project -> (Project, Double) in
            let day = RevenueAnalytics.total(data.revenue, from: anomaly.day, through: anomaly.day, projectID: project.id)
            let avg = RevenueAnalytics.total(data.revenue, from: before, through: anomaly.day.adding(days: -1, timeZone: utc), projectID: project.id) / 7
            return (project, day - avg)
        }
        if let biggest = deltas.max(by: { abs($0.1) < abs($1.1) }), abs(biggest.1) >= 1 {
            result.projectID = biggest.0.id
            causes.append("Most of the change came from \(biggest.0.name).")
        }

        if anomaly.direction == .drop {
            if let rejected = data.projects.first(where: {
                $0.signals.currentStoreVersion?.state == .rejected && now.days(since: $0.signals.storeStateChangedAt ?? .distantPast) <= 7
            }) {
                result.rejectedProject = rejected
                result.projectID = rejected.id
                causes.insert("\(rejected.name) was rejected in App Review.", at: 0)
            } else if let removed = data.projects.first(where: { $0.signals.currentStoreVersion?.state == .removed }) {
                causes.insert("\(removed.name) appears to be removed from sale.", at: 0)
            } else if let broken = data.projects.first(where: {
                $0.signals.ciStatus == .failure && now.days(since: $0.signals.ciUpdatedAt ?? .distantPast) <= 3
            }) {
                causes.append("The latest build of \(broken.name) failed.")
            }
        }

        // Did downloads move the same way?
        let dayDownloads = data.downloads.filter { $0.day == anomaly.day }.reduce(0) { $0 + $1.units }
        let priorDownloads = data.downloads.filter { $0.day >= before && $0.day < anomaly.day }.reduce(0) { $0 + $1.units }
        let avgDownloads = Double(priorDownloads) / 7
        if avgDownloads >= 5 {
            let ratio = Double(dayDownloads) / avgDownloads
            if ratio >= 2.5 {
                causes.append("Downloads were \(String(format: "%.1f", ratio))× normal — maybe a feature or a viral post.")
            } else if ratio <= 0.5 {
                causes.append("Downloads were down \(Int(((1 - ratio) * 100).rounded()))% too — fewer people found the app.")
            }
        }
        result.cause = causes.isEmpty ? nil : causes.joined(separator: " ")
        return result
    }
}
