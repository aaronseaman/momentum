import Foundation
import SwiftUI
import Observation
import MomentumKit
#if os(iOS)
import BackgroundTasks
#endif

enum AppTab: String, Hashable, CaseIterable, Identifiable {
    case today, radar, projects, money, review

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .radar: "Radar"
        case .projects: "Projects"
        case .money: "Money"
        case .review: "Review"
        }
    }

    var symbol: String {
        switch self {
        case .today: "sun.max"
        case .radar: "dot.radiowaves.left.and.right"
        case .projects: "square.stack.3d.up"
        case .money: "chart.line.uptrend.xyaxis"
        case .review: "calendar"
        }
    }
}

/// A running focus session.
struct FocusRun: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var minutes: Int
    var projectID: UUID?
    var stepID: UUID?
    var startedAt: Date
    var endsAt: Date { startedAt.addingTimeInterval(TimeInterval(minutes * 60)) }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()
    static let refreshTaskID = "app.momentum.refresh"

    private(set) var data: MomentumData
    var tab: AppTab = .today
    var isOverwhelmed = false
    var focus: FocusRun?
    var focusFinished: FocusRun?
    var showSettings = false
    var showBatch = false
    var projectPath: [UUID] = []
    var radarPath: [UUID] = []
    var isSyncing = false
    var banner: String?
    var celebrate = 0

    @ObservationIgnored let store = EncryptedStore()
    @ObservationIgnored let secrets = Secrets()
    @ObservationIgnored let notifications = NotificationService()
    @ObservationIgnored let calendar = CalendarService()
    @ObservationIgnored let ambient = AmbientSound()
    @ObservationIgnored let http: HTTPClient = URLSessionHTTPClient()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var scheduleTask: Task<Void, Never>?
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var lastSyncAt: Date?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var storageBlocked = false

    init() {
        data = MomentumData()
        do {
            switch try store.load() {
            case .fresh: break
            case .loaded(let loaded): data = loaded
            case .recovered:
                data.notify(.info, "I couldn't open your previous data on this device, so I started fresh. The old file was kept.", at: Date())
            }
        } catch {
            // Keychain locked or unavailable: run from memory, and never overwrite the file this session.
            storageBlocked = true
        }
        notifications.onAction = { [weak self] action in self?.handle(action) }
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        update { Engine.appOpened(&$0, now: Date()) }
        tick()
        Task { await refresh() }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30 * 60)) } catch { return }
                guard let self else { return }
                self.tick()
                await self.refresh()
            }
        }
    }

    func becameActive() {
        update { Engine.appOpened(&$0, now: Date()) }
        tick()
        if lastSyncAt.map({ Date().timeIntervalSince($0) > 15 * 60 }) ?? true {
            Task { await refresh() }
        }
    }

    func enteredBackground() {
        saveNow()
        scheduleBackgroundRefresh()
    }

    func scheduleBackgroundRefresh() {
        #if os(iOS)
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = Date().addingTimeInterval(60 * 60)
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }

    func backgroundRefresh() async {
        scheduleBackgroundRefresh()
        await refresh()
        saveNowBlocking()
    }

    // MARK: Mutation & persistence

    func update(_ mutate: (inout MomentumData) -> Void) {
        mutate(&data)
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
        scheduleTask?.cancel()
        scheduleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            await self.notifications.reschedule(self.data)
        }
    }

    func saveNow() {
        guard !storageBlocked else { return }
        let snapshot = data
        let store = store
        Task.detached(priority: .utility) {
            try? store.save(snapshot)
        }
    }

    /// Writes synchronously. Used when iOS may suspend the app right after we return
    /// (background refresh, answering from a notification).
    func saveNowBlocking() {
        guard !storageBlocked else { return }
        saveTask?.cancel()
        try? store.save(data)
    }

    func tick() {
        var alerts: [AlertEvent] = []
        update { alerts = Engine.tick(&$0, now: Date()) }
        if !alerts.isEmpty {
            let snapshot = data
            Task { await notifications.post(alerts, data: snapshot) }
        }
    }

    // MARK: Sync

    func refresh() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        let now = Date()
        let includeResearch = SyncService.researchDue(data, now: now)
        if includeResearch {
            let visible = data.opportunities.filter(\.isVisible).count
            update { Reducers.addCandidates(into: &$0, limit: max(0, min(3, 8 - visible)), now: now) }
        }
        let projectsBefore = data.projects.count
        let output = await SyncService.run(makeSyncInput(includeResearch: includeResearch), http: http, now: now)
        apply(output, now: Date())
        lastSyncAt = Date()
        // Newly tracked repos get their first snapshot right away.
        if data.projects.count > projectsBefore, output.repos != nil {
            let second = await SyncService.run(makeSyncInput(includeResearch: false), http: http, now: Date())
            apply(second, now: Date())
        }
    }

    private func makeSyncInput(includeResearch: Bool) -> SyncInput {
        SyncInput(
            data: data,
            githubToken: data.integration(.github).isConnected ? secrets.string(.github) : nil,
            appStoreConnect: data.integration(.appStoreConnect).isConnected ? secrets.appStoreConnect : nil,
            revenueCatKey: data.integration(.revenueCat).isConnected ? secrets.string(.revenueCatKey) : nil,
            revenueCatProject: secrets.string(.revenueCatProject),
            stripeKey: data.integration(.stripe).isConnected ? secrets.string(.stripe) : nil,
            ai: textGenerator,
            includeResearch: includeResearch
        )
    }

    private func apply(_ output: SyncOutput, now: Date) {
        var alerts: [AlertEvent] = []
        update { d in
            if let repos = output.repos {
                Reducers.discoverRepos(repos, into: &d, now: now, connectedAt: d.integration(.github).connectedAt)
            }
            for snapshot in output.repoSnapshots { alerts += Reducers.apply(snapshot, into: &d, now: now) }
            for snapshot in output.ascSnapshots { alerts += Reducers.apply(snapshot, into: &d, now: now) }
            if let fx = output.fx { d.fxRates = fx }
            let fx = d.fxRates ?? .identity(d.preferences.baseCurrency)
            for sales in output.sales {
                let (revenue, downloads) = SalesReportParser.entries(sales.rows, day: sales.day, apps: d.storeApps, fx: fx)
                Reducers.replaceRevenue(source: .appStore, days: [sales.day], with: revenue, into: &d)
                Reducers.replaceDownloads(days: [sales.day], with: downloads, into: &d)
                if !d.fetchedReportDays.contains(sales.day) { d.fetchedReportDays.append(sales.day) }
            }
            d.fetchedReportDays = Array(d.fetchedReportDays.sorted().suffix(60))
            if let metrics = output.revenueCat { Reducers.apply(metrics, into: &d) }
            if let transactions = output.stripeTransactions {
                Reducers.replaceRevenue(source: .stripe, days: output.stripeDays, with: StripeClient.entries(transactions, fx: fx), into: &d)
            }
            if let subscriptions = output.stripeSubscriptions {
                Reducers.apply(SubscriptionMetrics(source: .stripe, mrr: StripeClient.mrr(subscriptions, fx: fx),
                                                   activeSubscriptions: subscriptions.count, fetchedAt: now), into: &d)
            }
            for opp in output.research { alerts += Reducers.applyResearch(opp, into: &d, now: now) }
            if !output.research.isEmpty { d.lastResearchAt = now }
            for (id, summary) in output.aiSummaries {
                if let i = d.opportunityIndex(id) { d.opportunities[i].aiSummary = summary }
            }
            for (id, steps) in output.aiSteps {
                if let i = d.projectIndex(id) { d.projects[i].applyAISteps(steps, now: now) }
            }
            for kind in output.succeeded {
                var state = d.integration(kind)
                state.lastSyncAt = now
                state.lastError = nil
                d.integrations[kind] = state
            }
            for (kind, message) in output.errors {
                var state = d.integration(kind)
                state.lastError = message
                d.integrations[kind] = state
            }
            Reducers.reattribute(&d)
            alerts += Engine.tick(&d, now: now)
        }
        if !alerts.isEmpty {
            let snapshot = data
            Task { await notifications.post(alerts, data: snapshot) }
        }
    }

    // MARK: AI

    var textGenerator: (any TextGenerator)? {
        switch data.preferences.aiMode {
        case .off: return nil
        case .onDevice: return OnDeviceGenerator.isAvailable ? OnDeviceGenerator() : nil
        case .claude: return secrets.string(.claude).map { ClaudeClient(apiKey: $0, http: http) }
        }
    }

    /// Breaks one project's next steps down with AI right now (falls back to rules).
    func refreshSteps(for projectID: UUID) async {
        guard let project = data.project(projectID) else { return }
        guard let ai = textGenerator else {
            update { d in
                guard let i = d.projectIndex(projectID) else { return }
                d.projects[i].steps.removeAll { !$0.isDone && $0.source == .template }
                Planner.restock(&d.projects[i], now: Date())
            }
            return
        }
        do {
            let text = try await ai.generate(system: AIPrompts.system, prompt: AIPrompts.stepsPrompt(project: project), maxTokens: 2_000)
            let steps = AIPrompts.parseSteps(text, now: Date())
            update { d in
                guard let i = d.projectIndex(projectID) else { return }
                d.projects[i].applyAISteps(Array(steps.prefix(6)), now: Date())
            }
        } catch {
            banner = (error as? LocalizedError)?.errorDescription ?? "AI is unavailable right now."
        }
    }

    // MARK: Derived state

    var nextAction: NextAction {
        Planner.nextAction(data, now: Date()) ?? Planner.setupAction(data)
    }

    var currentQuestion: Question? { QuestionEngine.current(data, now: Date()) }

    var pendingQuestionCount: Int { QuestionEngine.remainingCount(data, now: Date()) }

    var money: MoneySummary { RevenueAnalytics.summary(data, now: Date()) }

    var currency: String { data.preferences.baseCurrency }

    var topOpportunity: Opportunity? {
        data.opportunities.filter { $0.isVisible && $0.opportunityScore != nil }
            .max { ($0.opportunityScore ?? 0) < ($1.opportunityScore ?? 0) }
    }

    // MARK: Questions

    func answer(_ questionID: UUID, _ optionID: String) {
        var effects: [AnswerEffect] = []
        withAnimation(.snappy) {
            update { effects = QuestionEngine.answer(questionID, optionID: optionID, data: &$0, now: Date()) }
        }
        for effect in effects { perform(effect) }
    }

    private func perform(_ effect: AnswerEffect) {
        switch effect {
        case .showMoney: tab = .money
        case .showRadar(let id):
            tab = .radar
            if let id { radarPath = [id] }
        case .showProject(let id):
            tab = .projects
            projectPath = [id]
        case .planTomorrow: planTomorrow()
        case .startFocus: startFocus()
        }
    }

    func changeAssumption(_ notice: Notice) {
        guard let qid = notice.questionID else { return }
        update { d in
            QuestionEngine.reopen(qid, data: &d, now: Date())
            if let i = d.notices.firstIndex(where: { $0.id == notice.id }) { d.notices[i].isDismissed = true }
        }
        tab = .today
    }

    func dismiss(_ notice: Notice) {
        update { d in
            if let i = d.notices.firstIndex(where: { $0.id == notice.id }) { d.notices[i].isDismissed = true }
        }
    }

    // MARK: Focus

    func startFocus(minutes: Int? = nil, action: NextAction? = nil) {
        let action = action ?? nextAction
        let length = minutes ?? min(action.minutes, data.preferences.focusMinutes)
        let run = FocusRun(title: action.title, minutes: max(1, length), projectID: action.projectID, stepID: action.stepID, startedAt: Date())
        isOverwhelmed = false
        withAnimation(.easeInOut) { focus = run }
        if data.preferences.ambientSound { ambient.start() }
        Task { await notifications.scheduleFocusEnd(at: run.endsAt, title: run.title) }
    }

    func startTinyStep() {
        let action = nextAction
        let tiny = NextAction(title: action.tinyStep, minutes: 5, projectID: action.projectID, projectName: action.projectName,
                              stepID: nil, reason: "Just this.", tinyStep: action.tinyStep)
        startFocus(minutes: 5, action: tiny)
    }

    /// Ends the session. Partial sessions still count — no shame.
    func endFocus(completed: Bool) {
        guard let run = focus else { return }
        ambient.stop()
        notifications.cancelFocusEnd()
        let elapsed = max(1, Int(Date().timeIntervalSince(run.startedAt) / 60))
        update { d in
            d.focusSessions.append(FocusSession(startedAt: run.startedAt, plannedMinutes: run.minutes, actualMinutes: min(elapsed, run.minutes),
                                                projectID: run.projectID, stepID: run.stepID, title: run.title, completed: completed))
            if let i = d.projectIndex(run.projectID) { d.projects[i].lastTouchedAt = Date() }
            if completed { d.log(.focusCompleted, "Focused on “\(run.title)”", projectID: run.projectID, at: Date()) }
        }
        withAnimation(.easeInOut) {
            focus = nil
            focusFinished = run
        }
        if completed { celebrate += 1 }
    }

    /// The post-session "Did you finish it?" answer.
    func finishStep(_ run: FocusRun, outcome: String) {
        update { d in
            guard let i = d.projectIndex(run.projectID), let stepID = run.stepID else { return }
            switch outcome {
            case "done":
                QuestionEngine.completeStep(&d, projectIndex: i, stepID: stepID, now: Date())
            case "blocked":
                d.projects[i].isStuck = true
                d.projects[i].steps.insert(contentsOf: Planner.unstickSteps(projectName: d.projects[i].name, now: Date()), at: 0)
            default:
                break
            }
        }
        if outcome == "done" { celebrate += 1 }
        focusFinished = nil
    }

    // MARK: Actions

    func markDone(projectID: UUID?, stepID: UUID?) {
        guard let projectID, let stepID else { return }
        update { d in
            guard let i = d.projectIndex(projectID) else { return }
            QuestionEngine.completeStep(&d, projectIndex: i, stepID: stepID, now: Date())
        }
        celebrate += 1
    }

    /// "Not now": move this step to the back of the line, no judgement.
    func skip(_ action: NextAction) {
        guard let projectID = action.projectID, let stepID = action.stepID else { return }
        update { d in
            guard let i = d.projectIndex(projectID), let s = d.projects[i].steps.firstIndex(where: { $0.id == stepID }) else { return }
            let step = d.projects[i].steps.remove(at: s)
            d.projects[i].steps.append(step)
        }
    }

    func snooze(projectID: UUID?, hours: Double) {
        guard let projectID else { return }
        update { d in
            if let i = d.projectIndex(projectID) { d.projects[i].snoozedUntil = Date().addingTimeInterval(hours * 3600) }
        }
    }

    func planTomorrow() {
        let action = nextAction
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        let start = Calendar.current.date(bySettingHour: data.preferences.focusHour, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        let minutes = data.preferences.focusMinutes
        let timeText = start.formatted(date: .omitted, time: .shortened)
        Task {
            await notifications.scheduleFocusPrompt(title: "Time to \(action.title.lowercased())",
                                                    body: "\(minutes) minutes. Start whenever you're ready.", at: start)
            var blocked = false
            if data.preferences.calendarBlocking {
                blocked = await calendar.addFocusBlock(title: action.title, start: start, minutes: minutes)
            }
            update { d in
                d.notify(.info, "Tomorrow at \(timeText): \(action.title)\(blocked ? " (on your calendar)" : "").", at: Date())
            }
        }
    }

    func handle(_ action: NotificationService.Action) {
        switch action {
        case .answer(let qid, let option): answer(qid, option)
        case .startFocus: startFocus()
        case .snoozeFocus(let title, let body):
            Task { await notifications.scheduleFocusPrompt(title: title, body: body, at: Date().addingTimeInterval(30 * 60)) }
        case .planTomorrow: planTomorrow()
        case .open: tab = .today
        }
        saveNowBlocking()
    }

    // MARK: Projects

    func addProject(named name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        update { d in
            var project = Project(name: clean, createdAt: Date())
            Planner.restock(&project, now: Date())
            d.projects.append(project)
            d.log(.projectAdded, "New project: \(clean)", projectID: project.id, at: Date())
        }
    }

    func removeProject(_ id: UUID) {
        update { d in
            guard let project = d.project(id) else { return }
            if let repo = project.links.githubRepo, !d.dismissedRepos.contains(repo) { d.dismissedRepos.append(repo) }
            d.projects.removeAll { $0.id == id }
            d.questions.removeAll { $0.subjectID == id && $0.isPending }
            if d.profile.focusProjectID == id { d.profile.focusProjectID = nil }
        }
        projectPath.removeAll()
    }

    func setStage(_ id: UUID, _ stage: ProjectStage) {
        update { d in
            guard let i = d.projectIndex(id) else { return }
            QuestionEngine.setStage(&d, i, stage, now: Date())
        }
    }

    func setFocusProject(_ id: UUID?) {
        update { $0.profile.focusProjectID = id }
    }

    func imStuck(_ id: UUID) {
        update { d in
            guard let i = d.projectIndex(id) else { return }
            d.projects[i].isStuck = true
            d.projects[i].lastTouchedAt = Date()
            d.projects[i].steps.insert(contentsOf: Planner.unstickSteps(projectName: d.projects[i].name, now: Date()), at: 0)
        }
    }

    // MARK: Radar

    func research(keyword: String) {
        var id: UUID?
        update { id = Reducers.addKeyword(keyword, into: &$0, now: Date()) }
        if let id { radarPath = [id] }
        Task { await refresh() }
    }

    func setOpportunity(_ id: UUID, status: OpportunityStatus) {
        update { d in
            guard let i = d.opportunityIndex(id) else { return }
            d.opportunities[i].status = status
            d.profile.learn(tags: d.opportunities[i].tags, signal: status == .dismissed ? -0.6 : 0.6)
        }
    }

    func promote(_ id: UUID) {
        var projectID: UUID?
        update { d in
            guard let i = d.opportunityIndex(id) else { return }
            projectID = QuestionEngine.promote(&d, opportunityIndex: i, now: Date())
        }
        if let projectID {
            radarPath.removeAll()
            tab = .projects
            projectPath = [projectID]
        }
    }

    func answerFeature(_ id: UUID, _ feature: DifficultyFeature, _ answer: FeatureAnswer) {
        update { d in
            guard let i = d.opportunityIndex(id) else { return }
            d.opportunities[i].features[feature] = answer
            Scoring.rescore(&d.opportunities[i], profile: d.profile, shippedApps: d.projects.filter { $0.signals.liveVersion != nil }.count, now: Date())
        }
    }

    // MARK: Preferences & onboarding

    func setPreferences(_ change: (inout Preferences) -> Void) {
        update { change(&$0.preferences) }
    }

    func finishOnboarding(interests: [String], wantsNotifications: Bool) {
        update { d in
            d.profile.interests = interests
            d.profile.hasOnboarded = true
            for tag in interests { d.profile.learn(tags: [tag], signal: 1) }
        }
        if wantsNotifications {
            Task {
                _ = await notifications.requestPermission()
                await notifications.reschedule(data)
            }
        } else {
            setPreferences { $0.morningBrief = false; $0.middayCheckIn = false; $0.eveningSummary = false }
        }
        if started {
            Task { await refresh() }
        } else {
            start() // After "Delete all data" the background loop needs restarting.
        }
    }

    // MARK: Integrations

    func connectGitHub(token: String) async throws {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let login = try await GitHubClient(token: token, http: http).viewerLogin()
        try secrets.set(token, for: .github)
        markConnected(.github, label: "@\(login)")
        await refresh()
    }

    func connectAppStore(_ credentials: AppStoreConnectCredentials) async throws {
        let client = AppStoreConnectClient(tokens: ASCJWTSigner(credentials: credentials), vendorNumber: credentials.vendorNumber, http: http)
        let apps = try await client.apps(now: Date())
        try secrets.setAppStoreConnect(credentials)
        markConnected(.appStoreConnect, label: "\(apps.count) \(apps.count == 1 ? "app" : "apps")")
        await refresh()
    }

    func connectRevenueCat(key: String, projectID: String) async throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await RevenueCatClient(apiKey: key, projectID: project, http: http).metrics(now: Date())
        try secrets.set(key, for: .revenueCatKey)
        try secrets.set(project, for: .revenueCatProject)
        markConnected(.revenueCat, label: project)
        await refresh()
    }

    func connectStripe(key: String) async throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await StripeClient(apiKey: key, http: http).balanceTransactions(since: Date().addingTimeInterval(-86_400), maxPages: 1)
        try secrets.set(key, for: .stripe)
        markConnected(.stripe, label: key.hasPrefix("rk_") ? "Restricted key" : "Secret key")
        await refresh()
    }

    func setClaudeKey(_ key: String) async throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try await ClaudeClient(apiKey: key, http: http).validate()
        try secrets.set(key, for: .claude)
        setPreferences { $0.aiMode = .claude }
    }

    var hasClaudeKey: Bool { secrets.string(.claude) != nil }

    private func markConnected(_ kind: IntegrationKind, label: String) {
        update { d in
            d.integrations[kind] = IntegrationState(isConnected: true, connectedAt: Date(), accountLabel: label)
        }
    }

    func disconnect(_ kind: IntegrationKind) {
        switch kind {
        case .github: try? secrets.set(nil, for: .github)
        case .appStoreConnect: try? secrets.setAppStoreConnect(nil)
        case .revenueCat:
            try? secrets.set(nil, for: .revenueCatKey)
            try? secrets.set(nil, for: .revenueCatProject)
        case .stripe: try? secrets.set(nil, for: .stripe)
        }
        update { d in
            d.integrations[kind] = IntegrationState()
            if kind == .revenueCat { d.metrics.removeAll { $0.source == .revenueCat } }
            if kind == .stripe { d.metrics.removeAll { $0.source == .stripe } }
        }
    }

    // MARK: Export & privacy

    func exportJSON() -> Data { (try? Exporter.json(data)) ?? Data() }
    func exportCSV() -> String { Exporter.combinedCSV(data) }

    func deleteEverything() {
        loopTask?.cancel()
        loopTask = nil
        saveTask?.cancel()
        scheduleTask?.cancel()
        secrets.wipeAll()
        store.wipe()
        notifications.removeAll()
        data = MomentumData()
        storageBlocked = false
        started = false
        tab = .today
        projectPath.removeAll()
        radarPath.removeAll()
    }
}
