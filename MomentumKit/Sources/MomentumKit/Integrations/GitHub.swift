import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct GitHubRepo: Decodable, Hashable, Sendable {
    public var fullName: String
    public var name: String
    public var pushedAt: Date?
    public var createdAt: Date?
    public var fork: Bool
    public var archived: Bool
    public var description: String?

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name", name, pushedAt = "pushed_at", createdAt = "created_at", fork, archived, description
    }
}

/// What one sync learned about a tracked repo.
public struct RepoSnapshot: Hashable, Sendable {
    public var repo: String
    public var commitsLast7Days: Int
    public var commitsLast30Days: Int
    public var lastCommitAt: Date?
    public var ciStatus: CIStatus?
    public var ciUpdatedAt: Date?
    public var ciRunURL: String?
    public var latestReleaseTag: String?
    public var latestReleaseAt: Date?
    public var openIssues: [IssueRef]
}

public struct GitHubClient: Sendable {
    let token: String
    let http: HTTPClient
    let base = "https://api.github.com"

    public init(token: String, http: HTTPClient) {
        self.token = token
        self.http = http
    }

    var headers: [String: String] {
        [
            "Authorization": "Bearer \(token)",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "Momentum-App"
        ]
    }

    public func viewerLogin() async throws -> String {
        struct User: Decodable { let login: String }
        return try await http.json(User.self, URLRequest(URL.make("\(base)/user"), headers: headers), service: "GitHub").login
    }

    /// Repos the person owns or collaborates on, most recently pushed first.
    public func repos() async throws -> [GitHubRepo] {
        let url = URL.make("\(base)/user/repos", [("per_page", "100"), ("sort", "pushed"), ("affiliation", "owner,collaborator")])
        return try await http.json([GitHubRepo].self, URLRequest(url, headers: headers), service: "GitHub")
    }

    public func snapshot(repo: String, now: Date) async throws -> RepoSnapshot {
        async let commits = commitDates(repo: repo, since: now.addingTimeInterval(-30 * 86_400))
        async let run = latestRun(repo: repo)
        async let release = latestRelease(repo: repo)
        async let issues = openIssues(repo: repo)

        let dates = try await commits
        let latestRun = try? await run
        let latestRelease = try? await release
        let issueList = (try? await issues) ?? []
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        var lastCommit = dates.max()
        if lastCommit == nil { lastCommit = try? await lastCommitDate(repo: repo) }
        return RepoSnapshot(
            repo: repo,
            commitsLast7Days: dates.filter { $0 >= weekAgo }.count,
            commitsLast30Days: dates.count,
            lastCommitAt: lastCommit,
            ciStatus: latestRun?.status,
            ciUpdatedAt: latestRun?.updatedAt,
            ciRunURL: latestRun?.url,
            latestReleaseTag: latestRelease?.tag,
            latestReleaseAt: latestRelease?.publishedAt,
            openIssues: issueList
        )
    }

    // MARK: Endpoints

    struct CommitItem: Decodable {
        struct Inner: Decodable {
            struct Person: Decodable { let date: Date? }
            let committer: Person?
            let author: Person?
        }
        let commit: Inner
        var date: Date? { commit.committer?.date ?? commit.author?.date }
    }

    func commitDates(repo: String, since: Date) async throws -> [Date] {
        let url = URL.make("\(base)/repos/\(repo)/commits", [("since", JSONCoding.iso8601(since)), ("per_page", "100")])
        do {
            return try await http.json([CommitItem].self, URLRequest(url, headers: headers), service: "GitHub").compactMap(\.date)
        } catch IntegrationError.http(409, _) {
            return [] // Empty repository.
        }
    }

    func lastCommitDate(repo: String) async throws -> Date? {
        let url = URL.make("\(base)/repos/\(repo)/commits", [("per_page", "1")])
        return try await http.json([CommitItem].self, URLRequest(url, headers: headers), service: "GitHub").first?.date
    }

    struct RunList: Decodable {
        struct Run: Decodable {
            let status: String?
            let conclusion: String?
            let updatedAt: Date?
            let htmlURL: String?
            enum CodingKeys: String, CodingKey { case status, conclusion, updatedAt = "updated_at", htmlURL = "html_url" }
        }
        let workflowRuns: [Run]
        enum CodingKeys: String, CodingKey { case workflowRuns = "workflow_runs" }
    }

    struct RunInfo { let status: CIStatus; let updatedAt: Date?; let url: String? }

    func latestRun(repo: String) async throws -> RunInfo? {
        let url = URL.make("\(base)/repos/\(repo)/actions/runs", [("per_page", "1")])
        guard let run = try await http.json(RunList.self, URLRequest(url, headers: headers), service: "GitHub").workflowRuns.first else { return nil }
        return RunInfo(status: GitHubClient.ciStatus(status: run.status, conclusion: run.conclusion), updatedAt: run.updatedAt, url: run.htmlURL)
    }

    static func ciStatus(status: String?, conclusion: String?) -> CIStatus {
        if status != "completed" { return .running }
        switch conclusion {
        case "success", "neutral", "skipped": return .success
        case "cancelled": return .cancelled
        default: return .failure
        }
    }

    struct ReleaseItem: Decodable {
        let tagName: String
        let publishedAt: Date?
        let draft: Bool
        enum CodingKeys: String, CodingKey { case tagName = "tag_name", publishedAt = "published_at", draft }
    }

    struct ReleaseInfo { let tag: String; let publishedAt: Date? }

    func latestRelease(repo: String) async throws -> ReleaseInfo? {
        let url = URL.make("\(base)/repos/\(repo)/releases", [("per_page", "5")])
        let releases = try await http.json([ReleaseItem].self, URLRequest(url, headers: headers), service: "GitHub")
        return releases.first { !$0.draft }.map { ReleaseInfo(tag: $0.tagName, publishedAt: $0.publishedAt) }
    }

    struct IssueItem: Decodable {
        struct Label: Decodable { let name: String }
        struct PullRequestMarker: Decodable {}
        let number: Int
        let title: String
        let labels: [Label]
        let pullRequest: PullRequestMarker?
        enum CodingKeys: String, CodingKey { case number, title, labels, pullRequest = "pull_request" }
    }

    func openIssues(repo: String) async throws -> [IssueRef] {
        let url = URL.make("\(base)/repos/\(repo)/issues", [("state", "open"), ("per_page", "20"), ("sort", "updated")])
        return try await http.json([IssueItem].self, URLRequest(url, headers: headers), service: "GitHub")
            .filter { $0.pullRequest == nil }
            .map { issue in
                let isBug = issue.labels.contains { $0.name.lowercased().contains("bug") } || issue.title.lowercased().contains("crash")
                return IssueRef(number: issue.number, title: issue.title, isBug: isBug)
            }
    }
}
