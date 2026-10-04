import Foundation

/// Decides the single next action and keeps every project stocked with tiny steps.
public enum Planner {

    // MARK: Step templates (used when AI is off or unavailable)

    public static func templateSteps(for stage: ProjectStage, projectName name: String, now: Date) -> [MicroStep] {
        func step(_ title: String, _ minutes: Int, _ energy: EnergyLevel) -> MicroStep {
            MicroStep(title: title, minutes: minutes, energy: energy, source: .template, createdAt: now)
        }
        switch stage {
        case .idea:
            return [
                step("Write one sentence: who is \(name) for?", 5, .low),
                step("Sketch the main screen of \(name) on paper", 15, .medium),
                step("Create the Xcode project for \(name) and commit it", 15, .medium),
                step("Build the one core interaction with fake data", 25, .high)
            ]
        case .prototype:
            return [
                step("Open \(name) and run it once", 5, .low),
                step("Write down the 3 features \(name) needs to ship", 10, .low),
                step("Build the next screen of \(name) with fake data", 25, .high),
                step("Replace fake data with real storage", 25, .high)
            ]
        case .mvp:
            return [
                step("List what's left before \(name) can go to TestFlight", 10, .low),
                step("Fix the most annoying bug in \(name)", 25, .medium),
                step("Add an app icon placeholder and launch screen", 15, .low),
                step("Upload a TestFlight build of \(name)", 25, .medium)
            ]
        case .beta:
            return [
                step("Send the \(name) TestFlight link to 3 people", 5, .low),
                step("Read beta feedback and pick one fix", 15, .low),
                step("Take 3 App Store screenshots of \(name)", 25, .medium),
                step("Write the App Store description for \(name)", 25, .medium)
            ]
        case .submitted:
            return [
                step("Check App Review status for \(name)", 5, .low),
                step("Draft a launch post for \(name)", 15, .medium),
                step("Prepare the first update's to-do list", 10, .low)
            ]
        case .live:
            return [
                step("Look at yesterday's numbers for \(name) for 2 minutes", 5, .low),
                step("Reply to the newest review of \(name)", 10, .low),
                step("Pick one improvement for the next \(name) update", 15, .medium),
                step("Improve the App Store keywords for \(name)", 25, .medium)
            ]
        case .updating:
            return [
                step("Finish the change you started in \(name)", 25, .medium),
                step("Bump the \(name) version and write release notes", 15, .low),
                step("Submit the \(name) update for review", 15, .medium)
            ]
        case .paused, .abandoned:
            return []
        }
    }

    /// Breaks "I'm stuck" into 5–15 minute steps.
    public static func unstickSteps(projectName name: String, now: Date) -> [MicroStep] {
        [
            MicroStep(title: "Open the \(name) project file", minutes: 5, energy: .low, source: .template, createdAt: now),
            MicroStep(title: "Write one sentence about what's blocking \(name)", minutes: 5, energy: .low, source: .template, createdAt: now),
            MicroStep(title: "Find the smallest piece of it you could try", minutes: 10, energy: .low, source: .template, createdAt: now),
            MicroStep(title: "Try that piece for 15 minutes — messy is fine", minutes: 15, energy: .medium, source: .template, createdAt: now),
            MicroStep(title: "Write down what you learned for next time", minutes: 5, energy: .low, source: .template, createdAt: now)
        ]
    }

    /// Steps that come straight from tool signals (failing CI, rejected build, bug issues).
    public static func signalSteps(for project: Project, now: Date) -> [MicroStep] {
        var steps: [MicroStep] = []
        let s = project.signals
        if s.ciStatus == .failure {
            steps.append(MicroStep(title: "Open the failing build for \(project.name) and read the first error", minutes: 15, energy: .medium, source: .signal, createdAt: now))
        }
        if s.currentStoreVersion?.state == .rejected {
            steps.append(MicroStep(title: "Read the App Review note for \(project.name) and write down the guideline number", minutes: 10, energy: .low, source: .signal, createdAt: now))
        }
        if let bug = s.openIssues.first(where: \.isBug) {
            steps.append(MicroStep(title: "Fix #\(bug.number): \(bug.title)", minutes: 25, energy: .medium, source: .signal, createdAt: now))
        }
        return steps
    }

    /// Makes sure every active project has open steps, adding signal-driven steps first.
    public static func restock(_ project: inout Project, now: Date) {
        guard project.stage.isActive else { return }
        let fresh = signalSteps(for: project, now: now)
        let freshTitles = Set(fresh.map(\.title))
        // Drop signal steps whose cause has gone away (e.g. CI is green again).
        project.steps.removeAll { !$0.isDone && $0.source == .signal && !freshTitles.contains($0.title) }
        let openTitles = Set(project.openSteps.map(\.title))
        // Signal steps jump the queue: they're the most concrete work there is.
        let added = fresh.filter { !openTitles.contains($0.title) }
        project.steps = added + project.openSteps + project.steps.filter(\.isDone)

        if project.openSteps.isEmpty {
            // Don't repeat a template step finished in the last two weeks.
            let recent = Set(project.steps.filter { $0.isDone && now.days(since: $0.completedAt ?? $0.createdAt) < 14 }.map(\.title))
            let templates = templateSteps(for: project.stage, projectName: project.name, now: now)
                .filter { !recent.contains($0.title) }
            project.steps.insert(contentsOf: templates, at: 0)
        }
        // Keep history bounded.
        if project.steps.count > 40 {
            let open = project.openSteps
            let recentDone = project.steps.filter(\.isDone).suffix(max(0, 40 - open.count))
            project.steps = open + recentDone
        }
    }

    // MARK: Choosing the next action

    /// Priority of a project for "what should I do now". Higher is more urgent.
    public static func priority(of project: Project, data: MomentumData, now: Date) -> Double {
        guard project.stage.isActive, !project.isSnoozed(now: now) else { return -1 }
        var score = 10.0
        if data.profile.focusProjectID == project.id { score += 25 }
        if project.signals.ciStatus == .failure { score += 20 }
        if project.signals.currentStoreVersion?.state == .rejected { score += 30 }
        if project.isStuck { score += 10 }
        switch project.stage {
        case .beta, .submitted, .updating: score += 12
        case .mvp: score += 9
        case .live: score += 6
        case .prototype: score += 5
        default: break
        }
        // Recently touched projects keep momentum; very stale ones drift down.
        let idle = Double(project.daysSinceActivity(now: now))
        score += max(-10, 8 - idle)
        let revenue = RevenueAnalytics.total(data.revenue, from: DayKey(now).adding(days: -30, timeZone: RevenueAnalytics.utc), through: DayKey(now), projectID: project.id)
        score += min(15, log10(max(1, revenue)) * 5)
        return score
    }

    public static func nextAction(_ data: MomentumData, now: Date) -> NextAction? {
        let energy = data.energyToday(now: now)
        let ranked = data.projects
            .map { ($0, priority(of: $0, data: data, now: now)) }
            .filter { $0.1 >= 0 }
            .sorted { $0.1 > $1.1 }

        for (project, _) in ranked {
            let open = project.openSteps
            guard !open.isEmpty else { continue }
            // Signal steps always win; otherwise pick the first step that fits today's energy.
            let pick = open.first { $0.source == .signal }
                ?? open.first { energy.canHandle($0.energy) && $0.minutes <= energy.comfortableMinutes }
                ?? open.min { $0.minutes < $1.minutes }!
            return NextAction(
                title: pick.title,
                minutes: min(pick.minutes, energy == .low ? 15 : pick.minutes),
                projectID: project.id,
                projectName: project.name,
                stepID: pick.id,
                reason: reason(for: project, energy: energy, now: now),
                tinyStep: tinyStep(for: pick, projectName: project.name)
            )
        }
        return nil
    }

    static func reason(for project: Project, energy: EnergyLevel, now: Date) -> String {
        if project.signals.currentStoreVersion?.state == .rejected { return "App Review needs a reply." }
        if project.signals.ciStatus == .failure { return "The latest build failed." }
        if project.isStuck { return "Small steps to get unstuck." }
        let idle = project.daysSinceActivity(now: now)
        if idle >= 5 { return "Picking \(project.name) back up, gently." }
        switch energy {
        case .low: return "Low energy today, so here's a short one."
        case .high: return "You've got energy — a meaty one."
        case .medium: return "Keeps \(project.name) moving."
        }
    }

    /// The smallest physical first move for a step.
    public static func tinyStep(for step: MicroStep, projectName: String) -> String {
        let lower = step.title.lowercased()
        if lower.hasPrefix("open ") || step.minutes <= 5 { return step.title }
        if lower.contains("write") || lower.contains("draft") || lower.contains("list") {
            return "Open a blank note and write the first line."
        }
        if lower.contains("screenshot") { return "Open \(projectName) in the Simulator." }
        if lower.contains("testflight") || lower.contains("submit") || lower.contains("review") {
            return "Open App Store Connect in your browser."
        }
        if lower.contains("reply") || lower.contains("send") { return "Open the message app you'll use." }
        return "Open the \(projectName) project file."
    }

    /// What to show when there's nothing to do: set something up instead.
    public static func setupAction(_ data: MomentumData) -> NextAction {
        if !data.integration(.github).isConnected && data.projects.isEmpty {
            return NextAction(title: "Connect GitHub so I can track your projects", minutes: 2, projectID: nil, projectName: nil,
                              stepID: nil, reason: "One-time setup. After this I watch your repos for you.",
                              tinyStep: "Open Settings → Integrations → GitHub.")
        }
        return NextAction(title: "Look at today's top opportunity on the Radar", minutes: 5, projectID: nil, projectName: nil,
                          stepID: nil, reason: "Nothing urgent. A good moment to explore.", tinyStep: "Open the Radar tab.")
    }
}
