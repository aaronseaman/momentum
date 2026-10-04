import Foundation

/// Export everything the person owns. Secrets are never part of `MomentumData`.
public enum Exporter {
    public static func json(_ data: MomentumData) throws -> Data {
        try JSONCoding.exportEncoder.encode(data)
    }

    public static func revenueCSV(_ data: MomentumData) -> String {
        let names = Dictionary(data.projects.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var rows = [["day", "source", "kind", "amount", "currency", "units", "app", "project"]]
        for e in data.revenue.sorted(by: { $0.day < $1.day }) {
            rows.append([e.day.rawValue, e.source.rawValue, e.kind.rawValue, String(format: "%.2f", e.amount),
                         data.preferences.baseCurrency, String(e.units), e.appName ?? e.appIdentifier ?? "",
                         e.projectID.flatMap { names[$0] } ?? ""])
        }
        return csv(rows)
    }

    public static func projectsCSV(_ data: MomentumData) -> String {
        var rows = [["name", "stage", "progress", "last_activity", "github", "app_store_id", "next_step"]]
        for p in data.projects {
            rows.append([p.name, p.stage.rawValue, String(format: "%.0f%%", p.progress * 100),
                         p.lastActivityAt.map(JSONCoding.iso8601) ?? "", p.links.githubRepo ?? "",
                         p.links.appStoreAppID ?? "", p.openSteps.first?.title ?? ""])
        }
        return csv(rows)
    }

    public static func opportunitiesCSV(_ data: MomentumData) -> String {
        var rows = [["keyword", "status", "opportunity_score", "momentum", "competition", "difficulty", "hours_low", "hours_high", "summary"]]
        for o in data.opportunities {
            rows.append([o.keyword, o.status.rawValue, o.opportunityScore.map(String.init) ?? "", o.momentumScore.map(String.init) ?? "",
                         o.competition.map { String($0.score) } ?? "", o.difficulty.map { String($0.score) } ?? "",
                         o.difficulty.map { String($0.hoursLow) } ?? "", o.difficulty.map { String($0.hoursHigh) } ?? "", o.summary ?? ""])
        }
        return csv(rows)
    }

    /// One combined CSV with a section per table, for people who just want "a spreadsheet".
    public static func combinedCSV(_ data: MomentumData) -> String {
        ["# Revenue", revenueCSV(data), "# Projects", projectsCSV(data), "# Opportunities", opportunitiesCSV(data)].joined(separator: "\n")
    }

    public static func csv(_ rows: [[String]]) -> String {
        rows.map { row in row.map(escape).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    static func escape(_ field: String) -> String {
        // Neutralise spreadsheet formula injection, then quote when needed.
        var value = field
        if let first = value.first, "=+-@".contains(first), Double(value) == nil { value = "'" + value }
        if value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}
