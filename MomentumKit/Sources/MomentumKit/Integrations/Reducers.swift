import Foundation

/// Folds integration results into the local database. Pure and idempotent.
public enum Reducers {

    // MARK: GitHub

    /// Auto-tracks recently active repos (zero input) and returns repos worth asking about.
    public static func discoverRepos(_ repos: [GitHubRepo], into data: inout MomentumData, now: Date, connectedAt: Date?) {
        let tracked = Set(data.projects.compactMap(\.links.githubRepo))
        let dismissed = Set(data.dismissedRepos)
        let fresh = repos.filter { !$0.fork && !$0.archived && !tracked.contains($0.fullName) && !dismissed.contains($0.fullName) }
        let isFirstSync = tracked.isEmpty && !data.projects.contains { $0.links.githubRepo != nil }

        if isFirstSync {
            let recent = fresh.filter { now.days(since: $0.pushedAt ?? .distantPast) <= 60 }.prefix(8)
            for repo in recent {
                var project = Project(name: Naming.displayName(fromRepo: repo.name), createdAt: now, links: ProjectLinks(githubRepo: repo.fullName))
                linkToExistingApp(&project, data: data)
                Planner.restock(&project, now: now)
                data.projects.append(project)
                data.log(.projectAdded, "Started tracking \(project.name)", projectID: project.id, at: now)
            }
            if !recent.isEmpty {
                let names = recent.map { Naming.displayName(fromRepo: $0.name) }
                data.notify(.info, "I started tracking \(names.count) \(names.count == 1 ? "repo" : "repos") as projects: \(names.joined(separator: ", ")). Remove any from Projects.", at: now)
            }
            return
        }

        // Later: only ask about genuinely new repos (created after connecting), one at a time.
        let cutoff = connectedAt ?? now
        if let newRepo = fresh.first(where: { ($0.createdAt ?? .distantPast) > cutoff && now.days(since: $0.pushedAt ?? .distantPast) <= 14 }) {
            QuestionEngine.enqueue(Question(
                kind: .trackRepo,
                prompt: "New repo “\(newRepo.name)”. Track it as a project?",
                options: [AnswerOption("yes", "Yes"), AnswerOption("no", "No")],
                defaultOptionID: "yes",
                assumption: "I started tracking “\(Naming.displayName(fromRepo: newRepo.name))” as a project. Tap to change.",
                context: ["repo": newRepo.fullName, "name": newRepo.name],
                priority: 50,
                dedupeKey: "repo-\(newRepo.fullName)",
                createdAt: now,
                lifetimeHours: 48
            ), into: &data)
        }
    }

    public static func apply(_ snapshot: RepoSnapshot, into data: inout MomentumData, now: Date) -> [AlertEvent] {
        guard let i = data.projects.firstIndex(where: { $0.links.githubRepo == snapshot.repo }) else { return [] }
        var alerts: [AlertEvent] = []
        let old = data.projects[i].signals
        var s = old
        s.commitsLast7Days = snapshot.commitsLast7Days
        s.commitsLast30Days = snapshot.commitsLast30Days
        s.lastCommitAt = [snapshot.lastCommitAt, old.lastCommitAt].compactMap { $0 }.max()
        s.ciStatus = snapshot.ciStatus
        s.ciUpdatedAt = snapshot.ciUpdatedAt
        s.ciRunURL = snapshot.ciRunURL
        s.latestReleaseTag = snapshot.latestReleaseTag
        s.latestReleaseAt = snapshot.latestReleaseAt
        s.openIssues = snapshot.openIssues
        data.projects[i].signals = s
        let name = data.projects[i].name
        let id = data.projects[i].id

        if snapshot.ciStatus != old.ciStatus || snapshot.ciUpdatedAt != old.ciUpdatedAt {
            if snapshot.ciStatus == .failure && old.ciStatus != .failure {
                data.log(.buildFailed, "\(name) build failed", projectID: id, at: now)
                alerts.append(AlertEvent(kind: .build, title: "\(name) build failed", body: "I added “read the first error” as your next step."))
            } else if snapshot.ciStatus == .success && old.ciUpdatedAt != nil && old.ciUpdatedAt != snapshot.ciUpdatedAt {
                data.log(.buildSucceeded, "\(name) build succeeded", projectID: id, at: now)
            }
        }
        if let tag = snapshot.latestReleaseTag, tag != old.latestReleaseTag, old.latestReleaseTag != nil || old.lastCommitAt != nil {
            data.log(.release, "\(name) released \(tag)", projectID: id, at: now)
        }
        return alerts
    }

    // MARK: App Store Connect

    public static func apply(_ snapshot: ASCAppSnapshot, into data: inout MomentumData, now: Date) -> [AlertEvent] {
        if let existing = data.storeApps.firstIndex(where: { $0.id == snapshot.app.id }) {
            data.storeApps[existing] = snapshot.app
        } else {
            data.storeApps.append(snapshot.app)
        }

        // Find or create the project this app belongs to.
        var index = data.projects.firstIndex { $0.links.appStoreAppID == snapshot.app.id }
        if index == nil {
            let key = Naming.normalized(snapshot.app.name)
            let candidates = data.projects.filter { $0.links.appStoreAppID == nil && $0.links.githubRepo != nil }
            if let match = candidates.first(where: { Naming.normalized($0.name) == key || Naming.normalized($0.links.githubRepo?.components(separatedBy: "/").last ?? "") == key }),
               let i = data.projects.firstIndex(where: { $0.id == match.id }) {
                data.projects[i].links.appStoreAppID = snapshot.app.id
                data.projects[i].links.bundleID = snapshot.app.bundleID
                data.projects[i].links.appName = snapshot.app.name
                index = i
            } else if !candidates.isEmpty, let guess = candidates.first {
                // Ambiguous: ask once, assume they're separate if ignored.
                QuestionEngine.enqueue(Question(
                    kind: .linkApp,
                    prompt: "Is the App Store app “\(snapshot.app.name)” the same as “\(guess.name)”?",
                    options: [AnswerOption("yes", "Yes"), AnswerOption("no", "No")],
                    defaultOptionID: "no",
                    subjectID: guess.id,
                    context: ["appID": snapshot.app.id, "appName": snapshot.app.name, "bundleID": snapshot.app.bundleID],
                    priority: 52,
                    dedupeKey: "link-\(snapshot.app.id)",
                    createdAt: now,
                    lifetimeHours: 48
                ), into: &data)
                return []
            } else {
                var project = Project(name: snapshot.app.name, createdAt: now,
                                      links: ProjectLinks(appStoreAppID: snapshot.app.id, bundleID: snapshot.app.bundleID, appName: snapshot.app.name))
                Planner.restock(&project, now: now)
                data.projects.append(project)
                data.log(.projectAdded, "Started tracking \(project.name) from App Store Connect", projectID: project.id, at: now)
                index = data.projects.count - 1
            }
        }
        guard let i = index else { return [] }

        var alerts: [AlertEvent] = []
        let old = data.projects[i].signals
        let name = data.projects[i].name
        data.projects[i].signals.liveVersion = snapshot.liveVersion
        data.projects[i].signals.latestBuildUploadedAt = snapshot.latestBuildAt
        if let current = snapshot.currentVersion {
            let changed = old.currentStoreVersion?.state != current.state || old.currentStoreVersion?.version != current.version
            data.projects[i].signals.currentStoreVersion = current
            if changed {
                data.projects[i].signals.storeStateChangedAt = now
                let isFirstObservation = old.currentStoreVersion == nil
                if !isFirstObservation {
                    data.log(.storeStateChanged, "\(name) \(current.version) is \(stateText(current.state))", projectID: data.projects[i].id, at: now)
                    switch current.state {
                    case .rejected:
                        alerts.append(AlertEvent(kind: .store, title: "\(name) \(current.version) was rejected", body: "Take a breath. I'll help you with the reply."))
                        QuestionEngine.enqueue(Question(
                            kind: .resubmit,
                            prompt: "\(name) \(current.version) failed review. Want to fix and resubmit?",
                            options: [AnswerOption("yes", "Yes"), AnswerOption("no", "No"), AnswerOption("later", "Later")],
                            subjectID: data.projects[i].id,
                            priority: 88,
                            dedupeKey: "resubmit-\(data.projects[i].id)-\(current.version)",
                            createdAt: now,
                            lifetimeHours: 48
                        ), into: &data)
                    case .live:
                        alerts.append(AlertEvent(kind: .store, title: "\(name) \(current.version) is live 🎉", body: "Shipped. That's a real win."))
                        data.notify(.win, "\(name) \(current.version) is live on the App Store.", at: now)
                    default:
                        break
                    }
                }
            }
        }
        return alerts
    }

    static func stateText(_ state: StoreState) -> String {
        switch state {
        case .preparing: "being prepared"
        case .waitingForReview: "waiting for review"
        case .inReview: "in review"
        case .pendingRelease: "approved, pending release"
        case .live: "live"
        case .rejected: "rejected"
        case .removed: "removed from sale"
        case .unknown: "in an unknown state"
        }
    }

    static func linkToExistingApp(_ project: inout Project, data: MomentumData) {
        let key = Naming.normalized(project.name)
        if let app = data.storeApps.first(where: { Naming.normalized($0.name) == key }),
           !data.projects.contains(where: { $0.links.appStoreAppID == app.id }) {
            project.links.appStoreAppID = app.id
            project.links.bundleID = app.bundleID
            project.links.appName = app.name
        }
    }

    // MARK: Money

    /// Replaces all entries for `source` on the given days (idempotent re-sync).
    public static func replaceRevenue(source: RevenueSource, days: Set<DayKey>, with entries: [RevenueEntry], into data: inout MomentumData) {
        data.revenue.removeAll { $0.source == source && days.contains($0.day) }
        data.revenue += entries.map { entry in
            var e = entry
            e.projectID = projectID(for: e, data: data)
            return e
        }
        data.revenue.sort { $0.day < $1.day }
    }

    public static func replaceDownloads(days: Set<DayKey>, with entries: [DownloadEntry], into data: inout MomentumData) {
        data.downloads.removeAll { days.contains($0.day) }
        data.downloads += entries.map { entry in
            var e = entry
            e.projectID = data.projects.first { $0.links.appStoreAppID == entry.appIdentifier }?.id
            return e
        }
    }

    public static func apply(_ metrics: SubscriptionMetrics, into data: inout MomentumData) {
        data.metrics.removeAll { $0.source == metrics.source }
        data.metrics.append(metrics)
    }

    static func projectID(for entry: RevenueEntry, data: MomentumData) -> UUID? {
        if let app = entry.appIdentifier, let project = data.projects.first(where: { $0.links.appStoreAppID == app }) {
            return project.id
        }
        if let name = entry.appName {
            let key = Naming.normalized(name)
            return data.projects.first { Naming.normalized($0.name) == key }?.id
        }
        // Single-product indie: all Stripe money belongs to the only live project.
        let live = data.projects.filter { $0.stage == .live || $0.stage == .updating }
        return entry.source == .stripe && live.count == 1 ? live[0].id : nil
    }

    /// Re-attributes revenue after projects were linked or renamed.
    public static func reattribute(_ data: inout MomentumData) {
        for i in data.revenue.indices {
            data.revenue[i].projectID = projectID(for: data.revenue[i], data: data)
        }
        for i in data.downloads.indices {
            data.downloads[i].projectID = data.projects.first { $0.links.appStoreAppID == data.downloads[i].appIdentifier }?.id
        }
    }

    // MARK: Radar

    public static func addCandidates(into data: inout MomentumData, limit: Int, now: Date) {
        let existing = Set(data.opportunities.map { $0.keyword.lowercased() })
        for candidate in InterestCatalog.candidates(interests: data.profile.interests, existing: existing, limit: limit) {
            var opp = Opportunity(keyword: candidate.keyword, tags: [candidate.tag], source: "Interests", createdAt: now)
            opp.features = Scoring.inferredFeatures(for: candidate.keyword)
            data.opportunities.append(opp)
        }
    }

    /// Adds a keyword the person typed (or tapped from related searches).
    @discardableResult
    public static func addKeyword(_ keyword: String, into data: inout MomentumData, now: Date) -> UUID? {
        let clean = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard clean.count >= 2 else { return nil }
        if let existing = data.opportunities.firstIndex(where: { $0.keyword.lowercased() == clean }) {
            data.opportunities[existing].status = .starred
            return data.opportunities[existing].id
        }
        var opp = Opportunity(keyword: clean, tags: InterestCatalog.tags(for: clean), source: "You", status: .starred, createdAt: now)
        opp.features = Scoring.inferredFeatures(for: clean)
        data.opportunities.append(opp)
        return opp.id
    }

    /// Which opportunities to research this sync: starred first, then best-fit candidates.
    public static func researchQueue(_ data: MomentumData, now: Date, limit: Int) -> [Opportunity] {
        let due = data.opportunities.filter { $0.needsResearch(now: now) }
        let starred = due.filter { $0.status == .starred }
        let rest = due.filter { $0.status != .starred }
            .sorted { Scoring.fit(tags: $0.tags, profile: data.profile) > Scoring.fit(tags: $1.tags, profile: data.profile) }
        return Array((starred + rest).prefix(limit))
    }

    public static func applyResearch(_ opp: Opportunity, into data: inout MomentumData, now: Date) -> [AlertEvent] {
        guard let i = data.opportunityIndex(opp.id) else { return [] }
        let wasResearched = data.opportunities[i].researchedAt != nil
        let oldGrowth = data.opportunities[i].trend?.growthPercent ?? 0
        // Preserve answers given while research was running.
        var merged = opp
        merged.features.merge(data.opportunities[i].features) { _, answered in answered }
        merged.status = data.opportunities[i].status == .candidate ? opp.status : data.opportunities[i].status
        Scoring.rescore(&merged, profile: data.profile, shippedApps: QuestionEngine.shippedApps(data), now: now)
        data.opportunities[i] = merged
        if !wasResearched {
            data.log(.opportunityFound, "Researched “\(merged.title)” (score \(merged.opportunityScore ?? 0))", at: now)
        }
        if let trend = merged.trend, trend.growthPercent >= 40, trend.mentionsThisWeek >= 10, oldGrowth < 40 {
            return [AlertEvent(kind: .trend, title: "“\(merged.title)” is up \(Int(trend.growthPercent.rounded()))%",
                          body: "Mentions jumped this week. It's on your Radar.")]
        }
        return []
    }
}
