import XCTest
@testable import MomentumKit

final class RevenueTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!

    func entries(values: [Double], endingAt end: DayKey) -> [RevenueEntry] {
        values.enumerated().map { i, v in
            RevenueEntry(day: end.adding(days: -(values.count - 1 - i), timeZone: utc), source: .appStore, kind: .purchase, amount: v)
        }
    }

    func testDropIsDetected() {
        let day = DayKey("2026-10-03")!
        var values = Array(repeating: 100.0, count: 14)
        values.append(40)
        let anomaly = RevenueAnalytics.anomaly(entries(values: values, endingAt: day), on: day)
        XCTAssertEqual(anomaly?.direction, .drop)
        XCTAssertEqual(anomaly.map { Int($0.percentChange.rounded()) }, -60)
    }

    func testNormalNoiseIsNotAnAnomaly() {
        let day = DayKey("2026-10-03")!
        let values = [90.0, 110, 95, 105, 100, 98, 102, 97, 103, 99, 101, 96, 104, 100, 92]
        XCTAssertNil(RevenueAnalytics.anomaly(entries(values: values, endingAt: day), on: day))
    }

    func testThinHistoryNeverAlerts() {
        let day = DayKey("2026-10-03")!
        XCTAssertNil(RevenueAnalytics.anomaly(entries(values: [5, 0, 0, 500], endingAt: day), on: day))
    }

    func testForecastFollowsTrend() {
        let points = (0..<28).map { DailyPoint(day: DayKey("2026-09-01")!.adding(days: $0, timeZone: utc), amount: Double(10 + $0)) }
        let next = RevenueAnalytics.forecast(points, days: 30)
        // Days 28…57 → sum of (10 + x) = 30*10 + (28+57)*30/2
        XCTAssertEqual(next, 300 + 1275, accuracy: 0.5)
    }

    func testSummaryAvoidsDoubleCountingMRR() {
        var data = SampleData.make()
        let withRC = RevenueAnalytics.summary(data, now: Date())
        XCTAssertEqual(withRC.mrr, 1_840)
        XCTAssertFalse(withRC.mrrIsEstimate)
        data.metrics = []
        let estimated = RevenueAnalytics.summary(data, now: Date())
        XCTAssertTrue(estimated.mrrIsEstimate)
        XCTAssertGreaterThan(estimated.mrr, 0)
    }

    func testAnomalyCreatesOneQuestionWithCause() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let yesterday = DayKey(now).adding(days: -1, timeZone: utc)
        var data = MomentumData()
        var p = Project(name: "FocusFox", stage: .live, createdAt: now)
        p.signals.currentStoreVersion = StoreVersion(version: "1.2", state: .rejected, createdAt: now)
        p.signals.storeStateChangedAt = now.addingTimeInterval(-2 * 86_400)
        data.projects = [p]
        var values = Array(repeating: 100.0, count: 14)
        values.append(30)
        data.revenue = entries(values: values, endingAt: yesterday).map { var e = $0; e.projectID = p.id; return e }
        let alerts = Engine.checkRevenue(&data, now: now)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(data.pendingQuestions.first?.kind, .resubmit)
        XCTAssertTrue(data.pendingQuestions.first!.prompt.contains("failed review"))
        XCTAssertTrue(Engine.checkRevenue(&data, now: now).isEmpty, "Only once per day")
    }

    func testMoneyQuery() {
        let now = Date()
        let data = SampleData.make(now: now)
        XCTAssertTrue(MoneyQuery.answer("How much did I make this month?", data: data, now: now).text.hasPrefix("You made"))
        XCTAssertTrue(MoneyQuery.answer("what's my MRR", data: data, now: now).text.hasPrefix("MRR is"))
        XCTAssertTrue(MoneyQuery.answer("how much did FocusFox make last month", data: data, now: now).text.contains("from FocusFox last month"))
        XCTAssertFalse(MoneyQuery.answer("did anything arrive today", data: data, now: now).text.hasPrefix("ARR"))
    }
}

final class ScoringTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testCompetitionScoreRange() {
        XCTAssertEqual(Scoring.competitionScore([], now: now), 1)
        let giant = Competitor(id: 1, name: "Giant", seller: "", rating: 4.8, ratingCount: 500_000, price: 0, formattedPrice: "Free",
                               lastUpdated: now, releaseDate: nil, genre: "", url: nil, iconURL: nil)
        let stale = Competitor(id: 2, name: "Stale", seller: "", rating: 2.5, ratingCount: 40, price: 0, formattedPrice: "Free",
                               lastUpdated: now.addingTimeInterval(-800 * 86_400), releaseDate: nil, genre: "", url: nil, iconURL: nil)
        XCTAssertGreaterThanOrEqual(Scoring.competitionScore(Array(repeating: giant, count: 5), now: now), 9)
        XCTAssertLessThanOrEqual(Scoring.competitionScore(Array(repeating: stale, count: 5), now: now), 2)
    }

    func testReviewMiningFindsGap() {
        let reviews = [
            Review(rating: 1, title: "Crashes", body: "It crashes every time I open it", date: nil),
            Review(rating: 2, title: "Buggy", body: "So many bugs, and the subscription is expensive", date: nil),
            Review(rating: 1, title: "Broken", body: "Doesn't work after update", date: nil),
            Review(rating: 5, title: "Love it", body: "Simple and clean", date: nil)
        ]
        let mined = Scoring.mineReviews(reviews)
        XCTAssertEqual(mined.complaints.first, "bugs and crashes")
        XCTAssertEqual(mined.gap, "rock-solid reliability")
        XCTAssertEqual(mined.praises.first, "simplicity")
    }

    func testDifficultyUsesFeaturesAndExperience() {
        let easy = Scoring.difficulty(features: [:], shippedApps: 0)
        let hard = Scoring.difficulty(features: [.realtimeVideo: .yes, .cloudSync: .yes, .compliance: .yes], shippedApps: 0)
        let hardButExperienced = Scoring.difficulty(features: [.realtimeVideo: .yes, .cloudSync: .yes, .compliance: .yes], shippedApps: 3)
        XCTAssertEqual(easy.score, 2)
        XCTAssertGreaterThan(hard.score, 7)
        XCTAssertLessThan(hardButExperienced.score, hard.score)
        XCTAssertLessThan(easy.hoursLow, easy.hoursHigh)
        XCTAssertEqual(Scoring.inferredFeatures(for: "ai journal with family sync")[.ai], .yes)
        XCTAssertEqual(Scoring.inferredFeatures(for: "ai journal with family sync")[.cloudSync], .yes)
    }

    func testMomentumAndOpportunityScoreBounds() {
        let hot = TrendSignal(mentionsThisWeek: 300, priorWeeklyAverage: 50, mentionsBySource: ["Reddit": 450], headlines: [], measuredAt: now)
        let cold = TrendSignal(mentionsThisWeek: 0, priorWeeklyAverage: 10, mentionsBySource: ["Reddit": 30], headlines: [], measuredAt: now)
        XCTAssertGreaterThan(Scoring.momentum(hot), 90)
        XCTAssertLessThan(Scoring.momentum(cold), 30)
        let best = Scoring.opportunityScore(momentum: 100, competition: 1, difficulty: 1, fit: 100)
        let worst = Scoring.opportunityScore(momentum: 0, competition: 10, difficulty: 10, fit: 0)
        XCTAssertEqual(best, 100)
        XCTAssertEqual(worst, 0)
    }

    func testFitLearnsFromAnswers() {
        var profile = UserProfile()
        let neutral = Scoring.fit(tags: ["finance"], profile: profile)
        profile.learn(tags: ["finance"], signal: -1)
        XCTAssertLessThan(Scoring.fit(tags: ["finance"], profile: profile), neutral)
        profile.interests = ["adhd"]
        XCTAssertGreaterThan(Scoring.fit(tags: ["adhd"], profile: profile), neutral)
    }

    func testCandidatesRoundRobinAcrossInterests() {
        let picks = InterestCatalog.candidates(interests: ["finance", "food"], existing: ["budget app"], limit: 4)
        XCTAssertEqual(picks.map(\.keyword), ["meal planner", "expense tracker", "recipe organizer", "subscription tracker"])
    }
}
