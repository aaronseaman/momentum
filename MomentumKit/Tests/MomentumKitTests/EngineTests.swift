import XCTest
@testable import MomentumKit

final class DayKeyTests: XCTestCase {
    func testParsingAndArithmetic() throws {
        let day = try XCTUnwrap(DayKey("2026-02-28"))
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(day.adding(days: 1, timeZone: utc).rawValue, "2026-03-01")
        XCTAssertEqual(day.adding(days: -59, timeZone: utc).rawValue, "2025-12-31")
        XCTAssertEqual(day.days(to: DayKey("2026-03-10")!), 10)
        XCTAssertNil(DayKey("2026-2-28"))
        XCTAssertEqual(DayKey.range(from: DayKey("2026-01-30")!, through: DayKey("2026-02-02")!).count, 4)
    }

    func testCodableRoundTrip() throws {
        let day = DayKey("2026-10-04")!
        let data = try JSONEncoder().encode([day])
        XCTAssertEqual(String(data: data, encoding: .utf8), "[\"2026-10-04\"]")
        XCTAssertEqual(try JSONDecoder().decode([DayKey].self, from: data), [day])
    }
}

final class StageInferenceTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testStoreStatesWin() {
        var p = Project(name: "A", createdAt: now)
        p.signals.commitsLast30Days = 40
        p.signals.currentStoreVersion = StoreVersion(version: "1.0", state: .inReview, createdAt: now)
        XCTAssertEqual(StageInference.infer(p), .submitted)
        p.signals.currentStoreVersion?.state = .live
        p.signals.liveVersion = "1.0"
        XCTAssertEqual(StageInference.infer(p), .live)
        p.signals.currentStoreVersion = StoreVersion(version: "1.1", state: .preparing, createdAt: now)
        XCTAssertEqual(StageInference.infer(p), .updating)
    }

    func testCommitOnlyStages() {
        var p = Project(name: "A", createdAt: now)
        XCTAssertNil(StageInference.infer(p))
        p.signals.commitsLast30Days = 5
        XCTAssertEqual(StageInference.infer(p), .prototype)
        p.signals.commitsLast30Days = 60
        XCTAssertEqual(StageInference.infer(p), .mvp)
        p.signals.latestBuildUploadedAt = now
        XCTAssertEqual(StageInference.infer(p), .beta)
    }

    func testUserDecisionIsRespectedUntilNewEvidence() {
        var p = Project(name: "A", createdAt: now.addingTimeInterval(-100 * 86_400))
        p.signals.commitsLast30Days = 3
        p.signals.lastCommitAt = now.addingTimeInterval(-20 * 86_400)
        p.stage = .paused
        p.stageSource = .user
        p.stageChangedAt = now.addingTimeInterval(-10 * 86_400)
        XCTAssertNil(StageInference.apply(to: &p, now: now))
        XCTAssertEqual(p.stage, .paused)

        // A new commit after pausing wakes it up.
        p.signals.lastCommitAt = now.addingTimeInterval(-86_400)
        XCTAssertEqual(StageInference.apply(to: &p, now: now), .paused)
        XCTAssertEqual(p.stage, .prototype)
        XCTAssertEqual(p.stageSource, .inferred)
    }

    func testUserSetBetaNotDowngradedByCommits() {
        var p = Project(name: "A", createdAt: now.addingTimeInterval(-100 * 86_400))
        p.stage = .beta
        p.stageSource = .user
        p.stageChangedAt = now.addingTimeInterval(-5 * 86_400)
        p.signals.commitsLast30Days = 4
        p.signals.lastCommitAt = now
        XCTAssertNil(StageInference.apply(to: &p, now: now))
        XCTAssertEqual(p.stage, .beta)
    }
}

final class QuestionEngineTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func stalledData() -> MomentumData {
        var data = MomentumData()
        var p = Project(name: "Recipe Radar", stage: .prototype, createdAt: now.addingTimeInterval(-30 * 86_400))
        p.signals.lastCommitAt = now.addingTimeInterval(-9 * 86_400)
        p.signals.commitsLast30Days = 2
        data.projects = [p]
        return data
    }

    func testStallQuestionAskedOncePerStall() {
        var data = stalledData()
        Engine.askAboutStalls(&data, now: now)
        Engine.askAboutStalls(&data, now: now.addingTimeInterval(3600))
        let stalls = data.questions.filter { $0.kind == .projectStall }
        XCTAssertEqual(stalls.count, 1)
        XCTAssertTrue(stalls[0].prompt.contains("9 days"))
        XCTAssertEqual(stalls[0].options.map(\.label), ["Active but slow", "Paused", "Abandoned", "I'm stuck"])
    }

    func testIgnoredQuestionAppliesSafeAssumptionAndTellsYou() {
        var data = stalledData()
        Engine.askAboutStalls(&data, now: now)
        QuestionEngine.expire(&data, now: now.addingTimeInterval(37 * 3600))
        XCTAssertEqual(data.projects[0].stage, .paused)
        XCTAssertEqual(data.projects[0].stageSource, .user)
        XCTAssertEqual(data.visibleNotices.first?.text, "I assumed “Recipe Radar” is paused. Tap to change.")
        XCTAssertEqual(data.questions[0].status, .assumed)

        // One tap to change: reopen and answer differently.
        let qid = data.questions[0].id
        QuestionEngine.reopen(qid, data: &data, now: now.addingTimeInterval(38 * 3600))
        QuestionEngine.answer(qid, optionID: "active", data: &data, now: now.addingTimeInterval(38 * 3600))
        XCTAssertTrue(data.projects[0].stage.isActive)
        XCTAssertTrue(data.visibleNotices.isEmpty)
    }

    func testStuckBreaksWorkIntoTinySteps() {
        var data = stalledData()
        Engine.askAboutStalls(&data, now: now)
        let effects = QuestionEngine.answer(data.questions[0].id, optionID: "stuck", data: &data, now: now)
        XCTAssertEqual(effects, [.showProject(data.projects[0].id)])
        XCTAssertTrue(data.projects[0].isStuck)
        XCTAssertEqual(data.projects[0].openSteps.first?.title, "Open the Recipe Radar project file")
        XCTAssertTrue(data.projects[0].openSteps.prefix(5).allSatisfy { $0.minutes <= 15 })
    }

    func testDailyBudgetLimitsQuestionsButUrgentOnesStillShow() {
        var data = MomentumData()
        data.preferences.maxQuestionsPerDay = 1
        for i in 0..<3 {
            QuestionEngine.enqueue(Question(kind: .energy, prompt: "Q\(i)", options: [AnswerOption("low", "Low")],
                                            priority: 50, dedupeKey: "q\(i)", createdAt: now), into: &data)
        }
        let first = QuestionEngine.current(data, now: now)!
        QuestionEngine.answer(first.id, optionID: "low", data: &data, now: now)
        XCTAssertNil(QuestionEngine.current(data, now: now), "Budget reached: no more routine questions today")
        QuestionEngine.enqueue(Question(kind: .resubmit, prompt: "Urgent", options: [AnswerOption("yes", "Yes")],
                                        priority: 88, dedupeKey: "urgent", createdAt: now), into: &data)
        XCTAssertEqual(QuestionEngine.current(data, now: now)?.prompt, "Urgent")
    }

    func testDedupeAndCooldown() {
        var data = MomentumData()
        let q = Question(kind: .interests, prompt: "More?", options: [AnswerOption("yes", "Yes")], context: ["tag": "adhd"],
                         dedupeKey: "interest-adhd", createdAt: now)
        XCTAssertTrue(QuestionEngine.enqueue(q, into: &data, cooldownDays: 30))
        XCTAssertFalse(QuestionEngine.enqueue(q, into: &data, cooldownDays: 30))
        QuestionEngine.answer(q.id, optionID: "yes", data: &data, now: now)
        XCTAssertEqual(data.profile.interests, ["adhd"])
        let again = Question(kind: .interests, prompt: "More?", options: [AnswerOption("yes", "Yes")], context: ["tag": "adhd"],
                             dedupeKey: "interest-adhd", createdAt: now.addingTimeInterval(86_400))
        XCTAssertFalse(QuestionEngine.enqueue(again, into: &data, cooldownDays: 30))
    }

    func testEnergyQuestionAndAssumption() {
        var data = MomentumData()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let morning = cal.date(bySettingHour: 8, minute: 0, second: 0, of: now)!
        Engine.askEnergy(&data, now: morning, calendar: cal)
        XCTAssertEqual(data.pendingQuestions.first?.kind, .energy)
        QuestionEngine.answer(data.pendingQuestions[0].id, optionID: "low", data: &data, now: morning)
        XCTAssertEqual(data.energyToday(now: morning), .low)
    }

    func testTrackRepoNoRemembersDismissal() {
        var data = MomentumData()
        let q = Question(kind: .trackRepo, prompt: "Track?", options: [AnswerOption("yes", "Yes"), AnswerOption("no", "No")],
                         context: ["repo": "me/side-thing", "name": "side-thing"], dedupeKey: "repo", createdAt: now)
        data.questions.append(q)
        QuestionEngine.answer(q.id, optionID: "no", data: &data, now: now)
        XCTAssertEqual(data.dismissedRepos, ["me/side-thing"])
        XCTAssertTrue(data.projects.isEmpty)
    }
}

final class PlannerTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testSignalStepsJumpTheQueueAndDisappearWhenFixed() {
        var p = Project(name: "FocusFox", stage: .mvp, createdAt: now)
        Planner.restock(&p, now: now)
        p.signals.ciStatus = .failure
        Planner.restock(&p, now: now)
        XCTAssertEqual(p.openSteps.first?.source, .signal)
        p.signals.ciStatus = .success
        Planner.restock(&p, now: now)
        XCTAssertFalse(p.openSteps.contains { $0.source == .signal })
    }

    func testNextActionRespectsEnergy() {
        var data = MomentumData()
        var p = Project(name: "Tide", stage: .prototype, createdAt: now)
        p.lastTouchedAt = now
        p.steps = [
            MicroStep(title: "Big refactor", minutes: 50, energy: .high, createdAt: now),
            MicroStep(title: "Rename a file", minutes: 5, energy: .low, createdAt: now)
        ]
        data.projects = [p]
        data.energy = EnergyCheckIn(day: DayKey(now), level: .low)
        XCTAssertEqual(Planner.nextAction(data, now: now)?.title, "Rename a file")
        data.energy = EnergyCheckIn(day: DayKey(now), level: .high)
        XCTAssertEqual(Planner.nextAction(data, now: now)?.title, "Big refactor")
    }

    func testPausedProjectsNeverProduceActions() {
        var data = MomentumData()
        var p = Project(name: "Old", stage: .paused, createdAt: now)
        p.steps = [MicroStep(title: "Something", createdAt: now)]
        data.projects = [p]
        XCTAssertNil(Planner.nextAction(data, now: now))
        XCTAssertEqual(Planner.setupAction(data).title, "Look at today's top opportunity on the Radar")
    }

    func testRestockDoesNotRepeatRecentlyDoneTemplates() {
        var p = Project(name: "X", stage: .submitted, createdAt: now)
        Planner.restock(&p, now: now)
        for i in p.steps.indices { p.steps[i].isDone = true; p.steps[i].completedAt = now }
        Planner.restock(&p, now: now)
        XCTAssertTrue(p.openSteps.isEmpty, "All templates were just done; don't nag with repeats")
        Planner.restock(&p, now: now.addingTimeInterval(15 * 86_400))
        XCTAssertFalse(p.openSteps.isEmpty)
    }
}

final class EngineTests: XCTestCase {
    func testTickOnSampleDataIsStableAndProducesOneNextAction() throws {
        let now = Date()
        var data = SampleData.make(now: now)
        Engine.tick(&data, now: now)
        Engine.tick(&data, now: now.addingTimeInterval(60))
        XCTAssertNotNil(Planner.nextAction(data, now: now))
        let keys = data.questions.filter(\.isPending).map(\.dedupeKey)
        XCTAssertEqual(keys.count, Set(keys).count, "No duplicate pending questions")
        XCTAssertEqual(data.questions.filter { $0.kind == .projectStall }.count, 1, "Recipe Radar is stalled")
    }

    func testCodableRoundTripOfWholeDatabase() throws {
        let data = SampleData.make()
        let encoded = try JSONCoding.encoder.encode(data)
        let decoded = try JSONCoding.storeDecoder.decode(MomentumData.self, from: encoded)
        XCTAssertEqual(decoded.projects, data.projects)
        XCTAssertEqual(decoded.opportunities, data.opportunities)
        XCTAssertEqual(decoded.revenue.count, data.revenue.count)
        // Feature answers are stored as a readable JSON object.
        XCTAssertTrue(String(data: encoded, encoding: .utf8)!.contains("\"features\":{"))
        // Exports use ISO-8601 dates.
        XCTAssertTrue(String(data: try Exporter.json(data), encoding: .utf8)!.contains("T"))
    }

    func testOldStoreWithMissingFieldsStillDecodes() throws {
        let json = #"{"version":1,"projects":[],"preferences":{"morningBrief":false}}"#
        let decoded = try JSONCoding.storeDecoder.decode(MomentumData.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.preferences.morningBrief)
        XCTAssertEqual(decoded.preferences.maxQuestionsPerDay, 3)
        XCTAssertTrue(decoded.questions.isEmpty)
    }

    func testWelcomeBackAfterAbsence() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var data = MomentumData()
        data.projects = [Project(name: "A", createdAt: now)]
        data.profile.lastOpenedAt = now.addingTimeInterval(-6 * 86_400)
        Engine.appOpened(&data, now: now)
        XCTAssertEqual(data.pendingQuestions.first?.prompt, "Welcome back. Want to pick up where you left off?")
        XCTAssertEqual(data.profile.lastOpenedAt, now)
    }
}
