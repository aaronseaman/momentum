import Foundation
import MomentumKit

/// Everything a sync needs, captured on the main actor as plain values.
struct SyncInput: Sendable {
    var data: MomentumData
    var githubToken: String?
    var appStoreConnect: AppStoreConnectCredentials?
    var revenueCatKey: String?
    var revenueCatProject: String?
    var stripeKey: String?
    var ai: (any TextGenerator)?
    var includeResearch: Bool
}

struct DaySales: Sendable {
    var day: DayKey
    var rows: [SalesRow]
}

/// Raw results; applied to the database on the main actor by `AppModel.apply`.
struct SyncOutput: Sendable {
    var repos: [GitHubRepo]?
    var repoSnapshots: [RepoSnapshot] = []
    var ascSnapshots: [ASCAppSnapshot] = []
    var sales: [DaySales] = []
    var revenueCat: SubscriptionMetrics?
    var stripeTransactions: [StripeClient.BalanceTransaction]?
    var stripeDays: Set<DayKey> = []
    var stripeSubscriptions: [StripeClient.Subscription]?
    var fx: FXRates?
    var research: [Opportunity] = []
    var aiSummaries: [UUID: String] = [:]
    var aiSteps: [UUID: [MicroStep]] = [:]
    var succeeded: Set<IntegrationKind> = []
    var errors: [IntegrationKind: String] = [:]
}

enum SyncService {
    static let pacific = TimeZone(identifier: "America/Los_Angeles")!

    static func run(_ input: SyncInput, http: HTTPClient, now: Date) async -> SyncOutput {
        var output = SyncOutput()
        let data = input.data

        async let fx = refreshFX(data, http: http, now: now)
        async let github = syncGitHub(input, http: http, now: now)
        async let appStore = syncAppStore(input, http: http, now: now)
        async let revenueCat = syncRevenueCat(input, http: http, now: now)
        async let stripe = syncStripe(input, http: http, now: now)
        async let research = runResearch(input, http: http, now: now)

        output.fx = await fx

        let gh = await github
        output.repos = gh.repos
        output.repoSnapshots = gh.snapshots
        record(gh.error, .github, input.githubToken != nil, into: &output)

        let asc = await appStore
        output.ascSnapshots = asc.snapshots
        output.sales = asc.sales
        record(asc.error, .appStoreConnect, input.appStoreConnect != nil, into: &output)

        let rc = await revenueCat
        output.revenueCat = rc.metrics
        record(rc.error, .revenueCat, input.revenueCatKey != nil, into: &output)

        let st = await stripe
        output.stripeTransactions = st.transactions
        output.stripeDays = st.days
        output.stripeSubscriptions = st.subscriptions
        record(st.error, .stripe, input.stripeKey != nil, into: &output)

        output.research = await research

        if let ai = input.ai {
            await enrich(&output, data: data, ai: ai, now: now)
        }
        return output
    }

    private static func record(_ error: String?, _ kind: IntegrationKind, _ configured: Bool, into output: inout SyncOutput) {
        guard configured else { return }
        if let error { output.errors[kind] = error } else { output.succeeded.insert(kind) }
    }

    private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: FX

    static func refreshFX(_ data: MomentumData, http: HTTPClient, now: Date) async -> FXRates? {
        let base = data.preferences.baseCurrency
        if let cached = data.fxRates, cached.base == base, now.timeIntervalSince(cached.fetchedAt) < 20 * 3600 { return nil }
        return try? await FXRates.fetch(base: base, http: http, now: now)
    }

    // MARK: GitHub

    struct GitHubResult: Sendable {
        var repos: [GitHubRepo]?
        var snapshots: [RepoSnapshot] = []
        var error: String?
    }

    static func syncGitHub(_ input: SyncInput, http: HTTPClient, now: Date) async -> GitHubResult {
        guard let token = input.githubToken else { return GitHubResult() }
        let client = GitHubClient(token: token, http: http)
        var result = GitHubResult()
        do {
            result.repos = try await client.repos()
        } catch {
            result.error = message(error)
            return result
        }
        let tracked = input.data.projects.filter { $0.stage != .abandoned }.compactMap(\.links.githubRepo)
        result.snapshots = await withTaskGroup(of: RepoSnapshot?.self) { group in
            for repo in tracked.prefix(15) {
                group.addTask { try? await client.snapshot(repo: repo, now: now) }
            }
            var snapshots: [RepoSnapshot] = []
            for await snapshot in group { if let snapshot { snapshots.append(snapshot) } }
            return snapshots
        }
        return result
    }

    // MARK: App Store Connect

    struct AppStoreResult: Sendable {
        var snapshots: [ASCAppSnapshot] = []
        var sales: [DaySales] = []
        var error: String?
    }

    static func salesDays(_ data: MomentumData, now: Date) -> [DayKey] {
        let yesterday = DayKey(now.addingTimeInterval(-86_400), timeZone: pacific)
        let fetched = Set(data.fetchedReportDays)
        return (0..<14).compactMap { offset in
            let day = yesterday.adding(days: -offset, timeZone: pacific)
            // Always re-check the last 3 days: Apple finalises reports late.
            return offset < 3 || !fetched.contains(day) ? day : nil
        }
    }

    static func syncAppStore(_ input: SyncInput, http: HTTPClient, now: Date) async -> AppStoreResult {
        guard let credentials = input.appStoreConnect else { return AppStoreResult() }
        let client = AppStoreConnectClient(tokens: ASCJWTSigner(credentials: credentials), vendorNumber: credentials.vendorNumber, http: http)
        var result = AppStoreResult()
        do {
            let apps = try await client.apps(now: now)
            for app in apps.prefix(25) {
                if let snapshot = try? await client.snapshot(app: app, now: now) {
                    result.snapshots.append(snapshot)
                }
            }
            if !credentials.vendorNumber.isEmpty {
                for day in salesDays(input.data, now: now) {
                    let rows = try await client.sales(day: day, now: now)
                    result.sales.append(DaySales(day: day, rows: rows))
                }
            }
        } catch {
            result.error = message(error)
        }
        return result
    }

    // MARK: RevenueCat

    struct RevenueCatResult: Sendable {
        var metrics: SubscriptionMetrics?
        var error: String?
    }

    static func syncRevenueCat(_ input: SyncInput, http: HTTPClient, now: Date) async -> RevenueCatResult {
        guard let key = input.revenueCatKey, let project = input.revenueCatProject else { return RevenueCatResult() }
        do {
            return RevenueCatResult(metrics: try await RevenueCatClient(apiKey: key, projectID: project, http: http).metrics(now: now))
        } catch {
            return RevenueCatResult(error: message(error))
        }
    }

    // MARK: Stripe

    struct StripeResult: Sendable {
        var transactions: [StripeClient.BalanceTransaction]?
        var days: Set<DayKey> = []
        var subscriptions: [StripeClient.Subscription]?
        var error: String?
    }

    static func syncStripe(_ input: SyncInput, http: HTTPClient, now: Date) async -> StripeResult {
        guard let key = input.stripeKey else { return StripeResult() }
        let client = StripeClient(apiKey: key, http: http)
        let hasHistory = input.data.revenue.contains { $0.source == .stripe }
        // Start at midnight so a re-synced day is always complete.
        let firstDay = DayKey(now.addingTimeInterval(-(hasHistory ? 3 : 30) * 86_400))
        var result = StripeResult()
        do {
            result.transactions = try await client.balanceTransactions(since: firstDay.date())
            result.days = Set(DayKey.range(from: firstDay, through: DayKey(now)))
            result.subscriptions = try? await client.activeSubscriptions()
        } catch {
            result.error = message(error)
        }
        return result
    }

    // MARK: Radar research

    static func researchDue(_ data: MomentumData, now: Date) -> Bool {
        if data.opportunities.contains(where: { $0.status == .starred && $0.researchedAt == nil }) { return true }
        guard let last = data.lastResearchAt else { return true }
        return now.timeIntervalSince(last) > 6 * 3600
    }

    static func runResearch(_ input: SyncInput, http: HTTPClient, now: Date) async -> [Opportunity] {
        guard input.includeResearch else { return [] }
        let prefs = input.data.preferences
        let client = ResearchClient(http: http, country: prefs.researchCountry, useReddit: prefs.useReddit, useHackerNews: prefs.useHackerNews)
        let queue = Reducers.researchQueue(input.data, now: now, limit: 3)
        let profile = input.data.profile
        let shipped = input.data.projects.filter { $0.signals.liveVersion != nil }.count
        return await withTaskGroup(of: Opportunity.self) { group in
            for opp in queue {
                group.addTask { await client.research(opp, profile: profile, shippedApps: shipped, now: now) }
            }
            var results: [Opportunity] = []
            for await result in group { results.append(result) }
            return results
        }
    }

    // MARK: AI enrichment (optional)

    static func enrich(_ output: inout SyncOutput, data: MomentumData, ai: any TextGenerator, now: Date) async {
        for opp in output.research.filter({ $0.competition != nil }).prefix(2) {
            if let text = try? await ai.generate(system: AIPrompts.system, prompt: AIPrompts.opportunityPrompt(opp), maxTokens: 1_500),
               let summary = AIPrompts.cleanSummary(text) {
                output.aiSummaries[opp.id] = summary
            }
        }
        for project in data.projects.filter({ $0.wantsAISteps(now: now) }).prefix(2) {
            if let text = try? await ai.generate(system: AIPrompts.system, prompt: AIPrompts.stepsPrompt(project: project), maxTokens: 2_000) {
                let steps = AIPrompts.parseSteps(text, now: now)
                if steps.count >= 2 { output.aiSteps[project.id] = Array(steps.prefix(6)) }
            }
        }
    }
}
