import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Topic catalog used to seed the Radar from someone's interests.
public enum InterestCatalog {
    public static let topics: [(tag: String, title: String, seeds: [String])] = [
        ("productivity", "Productivity", ["habit tracker", "focus timer", "pomodoro timer", "to do list", "time blocking", "daily planner", "screen time", "note taking"]),
        ("adhd", "ADHD & neurodivergent", ["adhd planner", "visual timer", "body doubling", "routine planner", "adhd focus", "task breakdown"]),
        ("health", "Health", ["water tracker", "sleep tracker", "medication reminder", "symptom tracker", "migraine tracker", "posture reminder"]),
        ("fitness", "Fitness", ["workout tracker", "running tracker", "home workout", "step counter", "yoga timer", "calisthenics"]),
        ("finance", "Money", ["budget app", "expense tracker", "subscription tracker", "savings goal", "net worth tracker", "bill reminder"]),
        ("education", "Learning", ["flashcards", "language learning", "study timer", "vocabulary builder", "math practice"]),
        ("food", "Food", ["meal planner", "recipe organizer", "grocery list", "calorie counter", "intermittent fasting", "pantry tracker"]),
        ("travel", "Travel", ["packing list", "trip planner", "travel journal", "currency converter"]),
        ("parenting", "Family", ["baby tracker", "chore chart", "kids reward chart", "family calendar"]),
        ("creativity", "Creativity", ["journal app", "mood board", "music practice", "photo editor", "writing app"]),
        ("lifestyle", "Lifestyle", ["plant care", "gratitude journal", "mood tracker", "decluttering", "affirmations"]),
        ("developer", "Developer tools", ["json viewer", "api client", "regex tester", "markdown editor", "git client"])
    ]

    public static func title(for tag: String) -> String { topics.first { $0.tag == tag }?.title ?? tag.capitalized }

    /// Tags whose seeds or names appear in a keyword.
    public static func tags(for keyword: String) -> [String] {
        let lower = keyword.lowercased()
        let matches = topics.filter { topic in
            topic.seeds.contains { lower.contains($0) || $0.contains(lower) } || lower.contains(topic.tag)
        }
        return matches.map(\.tag)
    }

    /// New candidate keywords for the given interests, skipping ones already on the Radar.
    public static func candidates(interests: [String], existing: Set<String>, limit: Int) -> [(keyword: String, tag: String)] {
        let tags = interests.isEmpty ? ["productivity", "adhd"] : interests
        var result: [(String, String)] = []
        var round = 0
        // Round-robin across interests so no single topic floods the Radar.
        while result.count < limit {
            var added = false
            for tag in tags {
                guard let seeds = topics.first(where: { $0.tag == tag })?.seeds, round < seeds.count else { continue }
                let seed = seeds[round]
                if !existing.contains(seed) && !result.contains(where: { $0.0 == seed }) {
                    result.append((seed, tag))
                    if result.count == limit { break }
                }
                added = true
            }
            if !added { break }
            round += 1
        }
        return result
    }
}

public struct ResearchClient: Sendable {
    let http: HTTPClient
    let country: String
    let useReddit: Bool
    let useHackerNews: Bool

    public init(http: HTTPClient, country: String = "us", useReddit: Bool = true, useHackerNews: Bool = true) {
        self.http = http
        self.country = country.lowercased()
        self.useReddit = useReddit
        self.useHackerNews = useHackerNews
    }

    // MARK: App Store

    struct SearchResponse: Decodable {
        struct App: Decodable {
            let trackId: Int
            let trackName: String
            let sellerName: String?
            let averageUserRating: Double?
            let userRatingCount: Int?
            let price: Double?
            let formattedPrice: String?
            let currentVersionReleaseDate: Date?
            let releaseDate: Date?
            let primaryGenreName: String?
            let trackViewUrl: String?
            let artworkUrl100: String?
        }
        let results: [App]
    }

    public func searchApps(_ term: String, limit: Int = 15) async throws -> [Competitor] {
        let url = URL.make("https://itunes.apple.com/search", [("term", term), ("entity", "software"), ("country", country), ("limit", String(limit))])
        return try ResearchClient.parseSearch(try await http.fetch(URLRequest(url), service: "App Store search"))
    }

    public static func parseSearch(_ data: Data) throws -> [Competitor] {
        let response = try JSONCoding.decoder.decode(SearchResponse.self, from: data)
        return response.results.map { app in
            Competitor(
                id: app.trackId, name: app.trackName, seller: app.sellerName ?? "",
                rating: app.averageUserRating ?? 0, ratingCount: app.userRatingCount ?? 0,
                price: app.price ?? 0, formattedPrice: app.formattedPrice ?? "Free",
                lastUpdated: app.currentVersionReleaseDate, releaseDate: app.releaseDate,
                genre: app.primaryGenreName ?? "", url: app.trackViewUrl, iconURL: app.artworkUrl100
            )
        }
    }

    public func reviews(appID: Int) async throws -> [Review] {
        let url = URL.make("https://itunes.apple.com/\(country)/rss/customerreviews/page=1/id=\(appID)/sortby=mostrecent/json")
        return try ResearchClient.parseReviews(try await http.fetch(URLRequest(url), service: "App Store reviews"))
    }

    public static func parseReviews(_ data: Data) throws -> [Review] {
        struct Label: Decodable { let label: String }
        struct Entry: Decodable {
            let rating: Label?
            let title: Label?
            let content: Label?
            let updated: Label?
            enum CodingKeys: String, CodingKey { case rating = "im:rating", title, content, updated }
        }
        struct Feed: Decodable {
            let entry: [Entry]?
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                // A single review comes back as an object instead of an array.
                if let many = try? c.decode([Entry].self, forKey: .entry) {
                    entry = many
                } else if let one = try? c.decode(Entry.self, forKey: .entry) {
                    entry = [one]
                } else {
                    entry = nil
                }
            }
            enum CodingKeys: String, CodingKey { case entry }
        }
        struct Root: Decodable { let feed: Feed }
        let root = try JSONDecoder().decode(Root.self, from: data)
        return (root.feed.entry ?? []).compactMap { entry in
            guard let rating = entry.rating.flatMap({ Int($0.label) }) else { return nil }
            return Review(rating: rating, title: entry.title?.label ?? "", body: entry.content?.label ?? "",
                          date: entry.updated.flatMap { JSONCoding.parseISO8601($0.label) })
        }
    }

    /// App Store search autocomplete — what people actually type. Unofficial; failures are ignored.
    public func searchHints(_ term: String) async -> [String] {
        let url = URL.make("https://search.itunes.apple.com/WebObjects/MZSearchHints.woa/wa/hints", [("clientApplication", "Software"), ("term", term)])
        guard let data = try? await http.fetch(URLRequest(url), service: "App Store hints") else { return [] }
        return ResearchClient.parseHints(data)
    }

    public static func parseHints(_ data: Data) -> [String] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let hints = plist["hints"] as? [[String: Any]] else { return [] }
        return hints.compactMap { $0["term"] as? String }
    }

    // MARK: Buzz

    public func hackerNewsMentions(_ term: String, since: Date) async throws -> [Headline] {
        let url = URL.make("https://hn.algolia.com/api/v1/search_by_date", [
            ("query", term), ("tags", "(story,comment)"),
            ("numericFilters", "created_at_i>\(Int(since.timeIntervalSince1970))"), ("hitsPerPage", "500")
        ])
        return try ResearchClient.parseHackerNews(try await http.fetch(URLRequest(url), service: "Hacker News"))
    }

    public static func parseHackerNews(_ data: Data) throws -> [Headline] {
        struct Hit: Decodable {
            let title: String?
            let storyTitle: String?
            let url: String?
            let objectID: String
            let createdAtI: Int
            enum CodingKeys: String, CodingKey { case title, storyTitle = "story_title", url, objectID, createdAtI = "created_at_i" }
        }
        struct Response: Decodable { let hits: [Hit] }
        return try JSONDecoder().decode(Response.self, from: data).hits.map { hit in
            Headline(title: hit.title ?? hit.storyTitle ?? "Comment", source: "Hacker News",
                     url: hit.url ?? "https://news.ycombinator.com/item?id=\(hit.objectID)",
                     date: Date(timeIntervalSince1970: TimeInterval(hit.createdAtI)))
        }
    }

    public func redditMentions(_ term: String) async throws -> [Headline] {
        let url = URL.make("https://www.reddit.com/search.json", [("q", term), ("sort", "new"), ("t", "month"), ("limit", "100"), ("type", "link")])
        let request = URLRequest(url, headers: ["User-Agent": "ios:app.momentum:1.0 (personal research)"])
        return try ResearchClient.parseReddit(try await http.fetch(request, service: "Reddit"))
    }

    public static func parseReddit(_ data: Data) throws -> [Headline] {
        struct Post: Decodable {
            let title: String
            let permalink: String?
            let createdUTC: Double
            enum CodingKeys: String, CodingKey { case title, permalink, createdUTC = "created_utc" }
        }
        struct Child: Decodable { let data: Post }
        struct Listing: Decodable { let children: [Child] }
        struct Root: Decodable { let data: Listing }
        return try JSONDecoder().decode(Root.self, from: data).data.children.map { child in
            Headline(title: child.data.title, source: "Reddit",
                     url: child.data.permalink.map { "https://www.reddit.com\($0)" },
                     date: Date(timeIntervalSince1970: child.data.createdUTC))
        }
    }

    /// Mentions this week vs the three weeks before, across enabled sources.
    public func trend(_ term: String, now: Date) async -> TrendSignal {
        let since = now.addingTimeInterval(-28 * 86_400)
        async let hn = optionalHackerNews(term, since: since)
        async let reddit = optionalReddit(term)
        var bySource: [String: [Headline]] = [:]
        if let items = await hn { bySource["Hacker News"] = items }
        if let items = await reddit { bySource["Reddit"] = items }
        return ResearchClient.trend(from: bySource, now: now)
    }

    func optionalHackerNews(_ term: String, since: Date) async -> [Headline]? {
        guard useHackerNews else { return nil }
        return try? await hackerNewsMentions(term, since: since)
    }

    func optionalReddit(_ term: String) async -> [Headline]? {
        guard useReddit else { return nil }
        return try? await redditMentions(term)
    }

    public static func trend(from bySource: [String: [Headline]], now: Date) -> TrendSignal {
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        let monthAgo = now.addingTimeInterval(-28 * 86_400)
        let all = bySource.values.flatMap { $0 }.filter { $0.date >= monthAgo }
        let thisWeek = all.filter { $0.date >= weekAgo }.count
        let prior = all.filter { $0.date < weekAgo }.count
        let headlines = all.filter { $0.title != "Comment" }.sorted { $0.date > $1.date }.prefix(5)
        return TrendSignal(
            mentionsThisWeek: thisWeek,
            priorWeeklyAverage: Double(prior) / 3,
            mentionsBySource: bySource.mapValues { $0.filter { $0.date >= monthAgo }.count },
            headlines: Array(headlines),
            measuredAt: now
        )
    }

    // MARK: Full research pass

    public func competition(_ term: String, now: Date) async throws -> CompetitionReport {
        let apps = try await searchApps(term)
        var reviews: [Review] = []
        for app in apps.sorted(by: { $0.ratingCount > $1.ratingCount }).prefix(3) {
            reviews += (try? await self.reviews(appID: app.id)) ?? []
        }
        let mined = Scoring.mineReviews(reviews)
        return CompetitionReport(
            competitors: apps,
            score: Scoring.competitionScore(apps, now: now),
            complaints: mined.complaints,
            praises: mined.praises,
            gap: mined.gap,
            summary: Scoring.competitionSummary(competitors: apps, complaints: mined.complaints, gap: mined.gap, now: now)
        )
    }

    /// Researches one opportunity end to end. Never throws: partial results are still useful.
    public func research(_ opportunity: Opportunity, profile: UserProfile, shippedApps: Int, now: Date) async -> Opportunity {
        var opp = opportunity
        let keyword = opportunity.keyword
        async let trendResult = trend(keyword, now: now)
        async let competitionResult = try? competition(keyword, now: now)
        async let hintResult = searchHints(keyword)

        opp.trend = await trendResult
        if let report = await competitionResult { opp.competition = report }
        let hints = await hintResult.filter { $0.lowercased() != opp.keyword.lowercased() }
        if !hints.isEmpty { opp.relatedKeywords = Array(hints.prefix(6)) }
        if opp.tags.isEmpty { opp.tags = InterestCatalog.tags(for: opp.keyword) }
        opp.researchedAt = now
        if opp.status == .candidate { opp.status = .researched }
        Scoring.rescore(&opp, profile: profile, shippedApps: shippedApps, now: now)
        opp.summary = Scoring.plainSummary(opp)
        return opp
    }
}
