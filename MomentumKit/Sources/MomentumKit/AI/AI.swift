import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Anything that can turn a prompt into text: Claude, Apple's on-device model, or a test double.
public protocol TextGenerator: Sendable {
    func generate(system: String, prompt: String, maxTokens: Int) async throws -> String
}

public enum AIError: Error, LocalizedError, Equatable {
    case notConfigured
    case refused
    case unavailable(String)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "AI isn't set up. Momentum is using its built-in rules."
        case .refused: "The model declined this request."
        case .unavailable(let reason): reason
        case .badResponse: "The model's answer couldn't be read."
        }
    }
}

/// Raw-HTTP Claude Messages API client (no Swift SDK exists).
public struct ClaudeClient: TextGenerator {
    public static let defaultModel = "claude-opus-5-5"

    let apiKey: String
    let model: String
    let http: HTTPClient

    public init(apiKey: String, model: String = ClaudeClient.defaultModel, http: HTTPClient) {
        self.apiKey = apiKey
        self.model = model
        self.http = http
    }

    public func makeRequest(system: String, prompt: String, maxTokens: Int) throws -> URLRequest {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            // Short, routine generations: keep effort low for speed and cost.
            "output_config": ["effort": "low"],
            // Re-route a safety-classifier refusal to the recommended fallback model server-side.
            "fallbacks": "default",
            "messages": [["role": "user", "content": prompt]]
        ]
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// Checks the key without generating anything (no token cost).
    public func validate() async throws {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1")!)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        _ = try await http.fetch(request, service: "Claude")
    }

    public func generate(system: String, prompt: String, maxTokens: Int) async throws -> String {
        let request = try makeRequest(system: system, prompt: prompt, maxTokens: maxTokens)
        let (data, response) = try await http.send(request)
        switch response.statusCode {
        case 200: return try ClaudeClient.parse(data)
        case 401, 403: throw IntegrationError.unauthorized("Claude")
        case 429, 529: throw IntegrationError.rateLimited
        default:
            let message = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw IntegrationError.http(response.statusCode, message)
        }
    }

    public static func parse(_ data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIError.badResponse }
        // Check the stop reason before reading content.
        if json["stop_reason"] as? String == "refusal" { throw AIError.refused }
        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw AIError.badResponse }
        return text
    }
}

/// Prompts and parsers for every AI-assisted feature. Each has a rule-based fallback elsewhere.
public enum AIPrompts {
    public static let system = """
    You are Momentum, a calm assistant for an indie app developer with ADHD. \
    Be concrete, kind and brief. Never use guilt or urgency. \
    When asked for steps, each step must be a single physical action that takes 5–25 minutes.
    """

    public static func stepsPrompt(project: Project, count: Int = 4) -> String {
        var lines = [
            "Project: \(project.name)",
            "Stage: \(project.stage.title)"
        ]
        if let ci = project.signals.ciStatus { lines.append("Latest CI: \(ci.rawValue)") }
        if let v = project.signals.currentStoreVersion { lines.append("App Store: version \(v.version), \(v.state.rawValue)") }
        let issues = project.signals.openIssues.prefix(5).map { "#\($0.number) \($0.title)" }
        if !issues.isEmpty { lines.append("Open issues: " + issues.joined(separator: "; ")) }
        let done = project.steps.filter(\.isDone).suffix(5).map(\.title)
        if !done.isEmpty { lines.append("Recently done: " + done.joined(separator: "; ")) }
        if project.isStuck { lines.append("They said they feel stuck. Start with the smallest possible step.") }
        lines.append("")
        lines.append("Suggest the next \(count) steps, in order. One per line, formatted exactly as: <minutes> | <step>")
        lines.append("No numbering, no extra text.")
        return lines.joined(separator: "\n")
    }

    public static func parseSteps(_ text: String, now: Date) -> [MicroStep] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            // Strip list markers such as "- ", "• ", "1. " or "2) ".
            if let marker = line.range(of: #"^([-•*]|\d+[.)])\s+"#, options: .regularExpression) {
                line.removeSubrange(marker)
            }
            let parts = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let minutes: Int
            let title: String
            if parts.count == 2, let m = Int(parts[0].filter(\.isNumber)) {
                minutes = m
                title = parts[1]
            } else {
                minutes = 15
                title = line
            }
            guard title.count >= 4, title.count <= 140 else { return nil }
            let clamped = max(5, min(50, minutes))
            let energy: EnergyLevel = clamped <= 10 ? .low : (clamped <= 25 ? .medium : .high)
            return MicroStep(title: title, minutes: clamped, energy: energy, source: .ai, createdAt: now)
        }
    }

    public static func opportunityPrompt(_ opp: Opportunity) -> String {
        var lines = ["Keyword people search for: \(opp.keyword)"]
        if let t = opp.trend {
            lines.append("Mentions this week: \(t.mentionsThisWeek); weekly average before: \(String(format: "%.1f", t.priorWeeklyAverage))")
            let heads = t.headlines.prefix(3).map(\.title)
            if !heads.isEmpty { lines.append("Recent headlines: " + heads.joined(separator: " / ")) }
        }
        if let c = opp.competition {
            let apps = c.competitors.prefix(5).map { "\($0.name) (\(String(format: "%.1f", $0.rating))★, \($0.ratingCount) ratings)" }
            lines.append("Top App Store apps: " + apps.joined(separator: "; "))
            if !c.complaints.isEmpty { lines.append("Common complaints in 1–2★ reviews: " + c.complaints.joined(separator: ", ")) }
        }
        lines.append("")
        lines.append("In 2–3 plain sentences (max 60 words): why people want this, what existing apps get wrong, and the gap an indie developer could fill. No preamble.")
        return lines.joined(separator: "\n")
    }

    public static func cleanSummary(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20 else { return nil }
        return String(trimmed.prefix(500))
    }
}
