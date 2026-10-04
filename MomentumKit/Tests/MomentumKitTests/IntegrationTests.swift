import XCTest
@testable import MomentumKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Serves canned responses keyed by URL path.
struct StubHTTP: HTTPClient {
    var routes: [String: (Int, String)]

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path
        let (status, body) = routes.first { path.hasSuffix($0.key) }?.value ?? (404, "{}")
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

final class GitHubTests: XCTestCase {
    func testSnapshotParsesCommitsRunsReleasesAndIssues() async throws {
        let now = JSONCoding.parseISO8601("2026-10-04T12:00:00Z")!
        let http = StubHTTP(routes: [
            "/commits": (200, """
            [{"commit":{"committer":{"date":"2026-10-03T10:00:00Z"}}},
             {"commit":{"committer":{"date":"2026-09-20T10:00:00Z"}}}]
            """),
            "/actions/runs": (200, #"{"workflow_runs":[{"status":"completed","conclusion":"failure","updated_at":"2026-10-03T11:00:00Z","html_url":"https://x"}]}"#),
            "/releases": (200, #"[{"tag_name":"v1.2.0","published_at":"2026-09-30T08:00:00Z","draft":false}]"#),
            "/issues": (200, """
            [{"number":7,"title":"Crash on launch","labels":[]},
             {"number":8,"title":"PR","labels":[],"pull_request":{}},
             {"number":9,"title":"Dark mode","labels":[{"name":"enhancement"}]}]
            """)
        ])
        let snap = try await GitHubClient(token: "t", http: http).snapshot(repo: "me/app", now: now)
        XCTAssertEqual(snap.commitsLast7Days, 1)
        XCTAssertEqual(snap.commitsLast30Days, 2)
        XCTAssertEqual(snap.ciStatus, .failure)
        XCTAssertEqual(snap.latestReleaseTag, "v1.2.0")
        XCTAssertEqual(snap.openIssues.map(\.number), [7, 9])
        XCTAssertTrue(snap.openIssues[0].isBug)

        var data = MomentumData()
        data.projects = [Project(name: "App", createdAt: now, links: ProjectLinks(githubRepo: "me/app"))]
        let alerts = Reducers.apply(snap, into: &data, now: now)
        XCTAssertEqual(alerts.first?.kind, .build)
        Planner.restock(&data.projects[0], now: now)
        XCTAssertEqual(data.projects[0].openSteps.first?.source, .signal)
    }

    func testUnauthorizedMapsToFriendlyError() async {
        let http = StubHTTP(routes: ["/user": (401, "{}")])
        do {
            _ = try await GitHubClient(token: "bad", http: http).viewerLogin()
            XCTFail("Expected error")
        } catch {
            XCTAssertEqual(error as? IntegrationError, .unauthorized("GitHub"))
        }
    }

    func testFirstSyncAutoTracksRecentReposOnly() {
        let now = JSONCoding.parseISO8601("2026-10-04T12:00:00Z")!
        func repo(_ name: String, pushedDaysAgo: Double, fork: Bool = false) -> GitHubRepo {
            GitHubRepo(fullName: "me/\(name)", name: name, pushedAt: now.addingTimeInterval(-pushedDaysAgo * 86_400),
                       createdAt: now.addingTimeInterval(-400 * 86_400), fork: fork, archived: false, description: nil)
        }
        var data = MomentumData()
        Reducers.discoverRepos([repo("focus-fox-ios", pushedDaysAgo: 2), repo("old-thing", pushedDaysAgo: 200),
                                repo("someone-elses", pushedDaysAgo: 1, fork: true)], into: &data, now: now, connectedAt: now)
        XCTAssertEqual(data.projects.map(\.name), ["Focus Fox"])
        XCTAssertEqual(data.visibleNotices.count, 1)
    }
}

final class AppStoreTests: XCTestCase {
    let report = """
    Provider\tProvider Country\tSKU\tDeveloper\tTitle\tVersion\tProduct Type Identifier\tUnits\tDeveloper Proceeds\tBegin Date\tEnd Date\tCustomer Currency\tCountry Code\tCurrency of Proceeds\tApple Identifier\tCustomer Price\tPromo Code\tParent Identifier
    APPLE\tUS\tFOX1\tMe\tFocusFox\t1.1\t1F\t40\t0\t10/03/2026\t10/03/2026\tUSD\tUS\tUSD\t1001\t0\t\t
    APPLE\tUS\tFOX_PRO_M\tMe\tPro Monthly\t\tIAY\t10\t2.79\t10/03/2026\t10/03/2026\tUSD\tUS\tUSD\t5001\t3.99\t\tFOX1
    APPLE\tUS\tFOX_PRO_M\tMe\tPro Monthly\t\tIAY\t3\t2.50\t10/03/2026\t10/03/2026\tEUR\tDE\tEUR\t5001\t3.99\t\tFOX1
    APPLE\tUS\tFOX_TIP\tMe\tTip\t\tIA1\t-1\t0.70\t10/03/2026\t10/03/2026\tUSD\tUS\tUSD\t5002\t0.99\t\tFOX1
    """

    func testSalesReportAggregation() {
        let rows = SalesReportParser.parse(report)
        XCTAssertEqual(rows.count, 4)
        let fx = FXRates(base: "USD", rates: ["EUR": 0.5], fetchedAt: Date())
        let apps = [StoreApp(id: "1001", name: "FocusFox", bundleID: "app.fox", sku: "FOX1")]
        let day = DayKey("2026-10-03")!
        let (revenue, downloads) = SalesReportParser.entries(rows, day: day, apps: apps, fx: fx)
        XCTAssertEqual(downloads, [DownloadEntry(day: day, units: 40, appIdentifier: "1001")])
        let subs = revenue.first { $0.kind == .subscription }!
        XCTAssertEqual(subs.amount, 27.9 + 15, accuracy: 0.001) // 10×2.79 USD + 3×2.50 EUR at 0.5
        XCTAssertEqual(subs.appIdentifier, "1001")
        XCTAssertEqual(revenue.first { $0.kind == .refund }?.amount, -0.7)
    }

    func testStoreStateMapping() {
        XCTAssertEqual(StoreState(appStoreConnectValue: "READY_FOR_SALE"), .live)
        XCTAssertEqual(StoreState(appStoreConnectValue: "READY_FOR_DISTRIBUTION"), .live)
        XCTAssertEqual(StoreState(appStoreConnectValue: "WAITING_FOR_REVIEW"), .waitingForReview)
        XCTAssertEqual(StoreState(appStoreConnectValue: "METADATA_REJECTED"), .rejected)
        XCTAssertEqual(StoreState(appStoreConnectValue: "SOMETHING_NEW"), .unknown)
    }

    func testRejectionAsksToResubmitAndAlerts() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var data = MomentumData()
        let app = StoreApp(id: "1001", name: "FocusFox", bundleID: "app.fox", sku: "FOX1")
        let inReview = ASCAppSnapshot(app: app, liveVersion: "1.1", currentVersion: StoreVersion(version: "1.2", state: .inReview, createdAt: now), latestBuildAt: now)
        _ = Reducers.apply(inReview, into: &data, now: now)
        XCTAssertEqual(data.projects.count, 1, "Unmatched app becomes a project")
        var rejected = inReview
        rejected.currentVersion?.state = .rejected
        let alerts = Reducers.apply(rejected, into: &data, now: now.addingTimeInterval(3600))
        XCTAssertEqual(alerts.first?.kind, .store)
        XCTAssertEqual(data.pendingQuestions.first?.kind, .resubmit)
    }

    func testGzipPassthroughForPlainText() throws {
        XCTAssertEqual(try Gzip.decompress(Data("plain".utf8)), Data("plain".utf8))
    }
}

final class RevenueClientTests: XCTestCase {
    func testRevenueCatOverview() throws {
        let json = """
        {"object":"overview_metrics","metrics":[
          {"id":"active_trials","value":12},{"id":"active_subscriptions","value":300},
          {"id":"mrr","value":1520.5},{"id":"revenue","value":1800},{"id":"new_customers","value":410}]}
        """
        let m = try RevenueCatClient.parseMetrics(Data(json.utf8), now: Date())
        XCTAssertEqual(m.mrr, 1520.5)
        XCTAssertEqual(m.activeSubscriptions, 300)
        XCTAssertEqual(m.activeTrials, 12)
    }

    func testStripeNetIncomeAndMRR() throws {
        let fx = FXRates(base: "USD", rates: ["JPY": 150], fetchedAt: Date())
        let txs = [
            StripeClient.BalanceTransaction(id: "1", net: 970, currency: "usd", created: 1_790_000_000, type: "charge"),
            StripeClient.BalanceTransaction(id: "2", net: 1500, currency: "jpy", created: 1_790_000_100, type: "charge"),
            StripeClient.BalanceTransaction(id: "3", net: -500, currency: "usd", created: 1_790_000_200, type: "refund"),
            StripeClient.BalanceTransaction(id: "4", net: -10000, currency: "usd", created: 1_790_000_300, type: "payout")
        ]
        let entries = StripeClient.entries(txs, fx: fx, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(entries.first { $0.kind == .purchase }?.amount, 19.7)
        XCTAssertEqual(entries.first { $0.kind == .refund }?.amount, -5)

        let subsJSON = """
        {"data":[{"id":"sub_1","items":{"data":[
          {"quantity":1,"price":{"unit_amount":1200,"currency":"usd","recurring":{"interval":"year","interval_count":1}}},
          {"quantity":2,"price":{"unit_amount":500,"currency":"usd","recurring":{"interval":"month","interval_count":1}}}]}}],
         "has_more":false}
        """
        let page = try JSONCoding.decoder.decode(StripeClient.Page<StripeClient.Subscription>.self, from: Data(subsJSON.utf8))
        XCTAssertEqual(StripeClient.mrr(page.data, fx: fx), 1 + 10)
    }
}

final class ResearchTests: XCTestCase {
    func testParsersAndTrend() throws {
        let search = #"{"resultCount":1,"results":[{"trackId":42,"trackName":"Streaks","sellerName":"Crunchy","averageUserRating":4.8,"userRatingCount":12000,"price":5.99,"formattedPrice":"$5.99","currentVersionReleaseDate":"2026-08-01T07:00:00Z","primaryGenreName":"Health"}]}"#
        let apps = try ResearchClient.parseSearch(Data(search.utf8))
        XCTAssertEqual(apps.first?.name, "Streaks")
        XCTAssertEqual(apps.first?.ratingCount, 12000)

        let rss = #"{"feed":{"entry":[{"im:rating":{"label":"1"},"title":{"label":"Crashes"},"content":{"label":"Crashes constantly"},"updated":{"label":"2026-09-30T10:00:00-07:00"}}]}}"#
        let reviews = try ResearchClient.parseReviews(Data(rss.utf8))
        XCTAssertEqual(reviews.first?.rating, 1)
        XCTAssertNotNil(reviews.first?.date)

        let single = #"{"feed":{"entry":{"im:rating":{"label":"5"},"title":{"label":"Great"},"content":{"label":"Love it"}}}}"#
        XCTAssertEqual(try ResearchClient.parseReviews(Data(single.utf8)).count, 1)

        let hints = """
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>hints</key><array>
        <dict><key>term</key><string>habit tracker</string></dict><dict><key>term</key><string>habit tracker adhd</string></dict>
        </array></dict></plist>
        """
        XCTAssertEqual(ResearchClient.parseHints(Data(hints.utf8)), ["habit tracker", "habit tracker adhd"])

        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let reddit = """
        {"data":{"children":[
          {"data":{"title":"Need an ADHD timer","permalink":"/r/ADHD/1","created_utc":\(now.timeIntervalSince1970 - 3600)}},
          {"data":{"title":"Old post","permalink":"/r/ADHD/2","created_utc":\(now.timeIntervalSince1970 - 10 * 86400)}}]}}
        """
        let headlines = try ResearchClient.parseReddit(Data(reddit.utf8))
        let hn = try ResearchClient.parseHackerNews(Data(#"{"hits":[{"title":"Show HN: timer","objectID":"9","created_at_i":\#(Int(now.timeIntervalSince1970) - 7200)}]}"#.utf8))
        let trend = ResearchClient.trend(from: ["Reddit": headlines, "Hacker News": hn], now: now)
        XCTAssertEqual(trend.mentionsThisWeek, 2)
        XCTAssertEqual(trend.priorWeeklyAverage, 1.0 / 3, accuracy: 0.001)
        XCTAssertEqual(trend.totalMentions, 3)
    }

    func testResearchDegradesGracefullyWhenSourcesFail() async {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let client = ResearchClient(http: StubHTTP(routes: [:]))
        let opp = Opportunity(keyword: "visual timer", tags: ["adhd"], source: "Interests", createdAt: now)
        let result = await client.research(opp, profile: UserProfile(), shippedApps: 0, now: now)
        XCTAssertNotNil(result.researchedAt)
        XCTAssertNotNil(result.opportunityScore)
        XCTAssertNil(result.competition)
    }
}

final class AITests: XCTestCase {
    func testClaudeRequestShape() throws {
        let request = try ClaudeClient(apiKey: "sk-test", http: StubHTTP(routes: [:])).makeRequest(system: "s", prompt: "p", maxTokens: 800)
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-test")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["fallbacks"] as? String, "default")
        XCTAssertNil(body["thinking"], "Opus 5.5 rejects disabled thinking; omit the field")
    }

    func testClaudeParsingAndRefusal() throws {
        let ok = #"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"Hello"}],"stop_reason":"end_turn"}"#
        XCTAssertEqual(try ClaudeClient.parse(Data(ok.utf8)), "Hello")
        let refused = #"{"content":[],"stop_reason":"refusal"}"#
        XCTAssertThrowsError(try ClaudeClient.parse(Data(refused.utf8))) { XCTAssertEqual($0 as? AIError, .refused) }
    }

    func testStepParsing() {
        let text = """
        5 | Open Xcode and run FocusFox
        - 15 | Fix the onboarding notification step
        2) Write release notes
        x
        """
        let steps = AIPrompts.parseSteps(text, now: Date())
        XCTAssertEqual(steps.map(\.title), ["Open Xcode and run FocusFox", "Fix the onboarding notification step", "Write release notes"])
        XCTAssertEqual(steps.map(\.minutes), [5, 15, 15])
        XCTAssertEqual(steps[0].energy, .low)
    }

    func testCSVEscaping() {
        XCTAssertEqual(Exporter.csv([["a,b", "say \"hi\"", "=SUM(A1)", "-12.5"]]), "\"a,b\",\"say \"\"hi\"\"\",'=SUM(A1),-12.5\n")
        XCTAssertTrue(Exporter.combinedCSV(SampleData.make()).contains("# Revenue"))
    }
}
