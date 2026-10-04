import Foundation

/// Realistic data for SwiftUI previews and tests. Never shown to real users.
public enum SampleData {
    public static func make(now: Date = Date()) -> MomentumData {
        var data = MomentumData()
        data.profile.hasOnboarded = true
        data.profile.interests = ["productivity", "adhd"]
        data.profile.lastOpenedAt = now
        data.integrations[.github] = IntegrationState(isConnected: true, lastSyncAt: now)
        data.integrations[.appStoreConnect] = IntegrationState(isConnected: true, lastSyncAt: now)

        var fox = Project(name: "FocusFox", stage: .live, createdAt: now.addingTimeInterval(-120 * 86_400),
                          links: ProjectLinks(githubRepo: "indie/focusfox", appStoreAppID: "1001", bundleID: "app.focusfox", appName: "FocusFox"))
        fox.signals.commitsLast7Days = 6
        fox.signals.commitsLast30Days = 31
        fox.signals.lastCommitAt = now.addingTimeInterval(-86_400)
        fox.signals.liveVersion = "1.1"
        fox.signals.currentStoreVersion = StoreVersion(version: "1.2", state: .preparing, createdAt: now.addingTimeInterval(-3 * 86_400))
        fox.signals.ciStatus = .success
        fox.signals.ciUpdatedAt = now.addingTimeInterval(-86_400)
        fox.signals.openIssues = [IssueRef(number: 42, title: "Onboarding skips the notification step", isBug: true)]
        fox.stage = .updating
        Planner.restock(&fox, now: now)

        var recipe = Project(name: "Recipe Radar", stage: .prototype, createdAt: now.addingTimeInterval(-60 * 86_400),
                             links: ProjectLinks(githubRepo: "indie/recipe-radar"))
        recipe.signals.commitsLast30Days = 4
        recipe.signals.lastCommitAt = now.addingTimeInterval(-9 * 86_400)
        Planner.restock(&recipe, now: now)

        var tide = Project(name: "Tide Timer", stage: .beta, createdAt: now.addingTimeInterval(-40 * 86_400),
                           links: ProjectLinks(githubRepo: "indie/tide-timer"))
        tide.signals.commitsLast7Days = 2
        tide.signals.commitsLast30Days = 12
        tide.signals.lastCommitAt = now.addingTimeInterval(-2 * 86_400)
        tide.signals.latestBuildUploadedAt = now.addingTimeInterval(-5 * 86_400)
        Planner.restock(&tide, now: now)

        data.projects = [fox, recipe, tide]

        let today = DayKey(now)
        for offset in 1...45 {
            let day = today.adding(days: -offset, timeZone: TimeZone(identifier: "UTC")!)
            let wave = 70 + 20 * sin(Double(offset) / 4) + Double(45 - offset) * 0.6
            data.revenue.append(RevenueEntry(day: day, source: .appStore, kind: .subscription, amount: (wave * 100).rounded() / 100,
                                             units: Int(wave / 4), appIdentifier: "1001", appName: "FocusFox", projectID: fox.id))
            data.revenue.append(RevenueEntry(day: day, source: .appStore, kind: .purchase, amount: 12, units: 3,
                                             appIdentifier: "1001", appName: "FocusFox", projectID: fox.id))
            data.downloads.append(DownloadEntry(day: day, units: 40 + offset % 9, appIdentifier: "1001", projectID: fox.id))
        }
        data.metrics = [SubscriptionMetrics(source: .revenueCat, mrr: 1_840, activeSubscriptions: 412, activeTrials: 37,
                                            revenueLast28Days: 2_310, newCustomersLast28Days: 520, fetchedAt: now)]

        var habit = Opportunity(keyword: "adhd habit tracker", relatedKeywords: ["habit tracker for adhd", "adhd routine app"],
                                tags: ["adhd", "productivity"], source: "Interests", status: .researched, createdAt: now.addingTimeInterval(-86_400))
        habit.trend = TrendSignal(mentionsThisWeek: 37, priorWeeklyAverage: 28, mentionsBySource: ["Reddit": 92, "Hacker News": 9],
                                  headlines: [Headline(title: "Finally found a habit tracker that doesn't shame me", source: "Reddit", url: nil, date: now)],
                                  measuredAt: now)
        habit.competition = CompetitionReport(
            competitors: [
                Competitor(id: 1, name: "Habitica", seller: "HabitRPG", rating: 4.0, ratingCount: 48_000, price: 0, formattedPrice: "Free",
                           lastUpdated: now.addingTimeInterval(-20 * 86_400), releaseDate: nil, genre: "Productivity", url: nil, iconURL: nil),
                Competitor(id: 2, name: "Streaks", seller: "Crunchy Bagel", rating: 4.8, ratingCount: 12_000, price: 5.99, formattedPrice: "$5.99",
                           lastUpdated: now.addingTimeInterval(-60 * 86_400), releaseDate: nil, genre: "Health & Fitness", url: nil, iconURL: nil),
                Competitor(id: 3, name: "Routinery", seller: "Routinery", rating: 3.4, ratingCount: 2_100, price: 0, formattedPrice: "Free",
                           lastUpdated: now.addingTimeInterval(-400 * 86_400), releaseDate: nil, genre: "Productivity", url: nil, iconURL: nil)
            ],
            score: 6, complaints: ["pricing and paywalls", "bugs and crashes"], praises: ["simplicity"], gap: "fair, simple pricing",
            summary: "2 strong competitors, led by Habitica. Average rating 4.1★. Users complain about pricing and paywalls, bugs and crashes. Gap: fair, simple pricing.")
        habit.researchedAt = now
        Scoring.rescore(&habit, profile: data.profile, shippedApps: 1, now: now)
        habit.summary = Scoring.plainSummary(habit)

        var timer = Opportunity(keyword: "visual timer", tags: ["adhd"], source: "Interests", createdAt: now)
        timer.features = Scoring.inferredFeatures(for: timer.keyword)
        data.opportunities = [habit, timer]

        data.focusSessions = (1...5).map { i in
            FocusSession(startedAt: now.addingTimeInterval(-Double(i) * 86_400 - 3600), plannedMinutes: 25, actualMinutes: 25,
                         projectID: fox.id, stepID: nil, title: "Fix onboarding bug", completed: true)
        }
        data.energy = EnergyCheckIn(day: today, level: .medium)
        return data
    }
}
