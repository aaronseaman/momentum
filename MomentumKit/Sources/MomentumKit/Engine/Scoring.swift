import Foundation

/// Transparent, deterministic scores. Every number on the Radar comes from here.
public enum Scoring {

    // MARK: Trend momentum (0–100)

    public static func momentum(_ trend: TrendSignal) -> Int {
        let volume = min(1, log10(Double(trend.totalMentions) + 1) / 2.5)
        let growth = min(1, max(0, (trend.growthPercent + 50) / 150))
        return Int((100 * (0.6 * growth + 0.4 * volume)).rounded())
    }

    // MARK: Competition (1–10, higher = harder)

    public static func competitionScore(_ competitors: [Competitor], now: Date) -> Int {
        guard !competitors.isEmpty else { return 1 }
        let strengths = competitors.prefix(10).map { app -> Double in
            let reach = min(1, log10(Double(app.ratingCount) + 1) / 5)
            let quality = app.rating / 5
            let age = app.lastUpdated.map { now.days(since: $0) } ?? 400
            let freshness = age <= 90 ? 1.0 : (age <= 365 ? 0.7 : 0.4)
            return reach * quality * freshness
        }
        let top = strengths.sorted(by: >).prefix(5)
        let mean = top.reduce(0, +) / Double(top.count)
        return max(1, min(10, Int((1 + 9 * mean * 1.25).rounded())))
    }

    // MARK: Review mining

    struct Theme {
        let label: String
        let gap: String
        let words: [String]
    }

    static let complaintThemes: [Theme] = [
        Theme(label: "bugs and crashes", gap: "rock-solid reliability", words: ["crash", "bug", "broken", "freez", "glitch", "doesn't work", "does not work", "not working", "stopped working"]),
        Theme(label: "too many ads", gap: "an ad-free experience", words: ["ads", "advert", "ad every", "commercial"]),
        Theme(label: "pricing and paywalls", gap: "fair, simple pricing", words: ["subscription", "paywall", "expensive", "price", "pay to", "money grab", "free trial", "overpriced"]),
        Theme(label: "sync and data loss", gap: "dependable sync", words: ["sync", "lost my", "data loss", "lost all", "backup", "icloud"]),
        Theme(label: "confusing design", gap: "a simple, calm interface", words: ["confusing", "cluttered", "complicated", "hard to use", "ui is", "interface is", "overwhelming"]),
        Theme(label: "slow performance", gap: "a fast, lightweight app", words: ["slow", "lag", "battery", "takes forever", "loading"]),
        Theme(label: "missing widgets", gap: "great widgets", words: ["widget"]),
        Theme(label: "no Android or iPad version", gap: "true cross-device support", words: ["android", "ipad", "mac version", "apple watch"]),
        Theme(label: "login and account issues", gap: "no-account onboarding", words: ["login", "log in", "sign in", "account", "password"]),
        Theme(label: "privacy concerns", gap: "privacy-first, local data", words: ["privacy", "data collection", "tracking", "permissions"]),
        Theme(label: "annoying notifications", gap: "gentle, useful reminders", words: ["notification", "reminder", "spam"])
    ]

    static let praiseThemes: [Theme] = [
        Theme(label: "simplicity", gap: "", words: ["simple", "easy", "clean", "minimal", "intuitive"]),
        Theme(label: "design", gap: "", words: ["beautiful", "design", "gorgeous", "aesthetic", "pretty"]),
        Theme(label: "widgets", gap: "", words: ["widget"]),
        Theme(label: "motivation", gap: "", words: ["motivat", "helps me", "life changing", "game changer", "streak"]),
        Theme(label: "customization", gap: "", words: ["custom", "flexible", "options"]),
        Theme(label: "good value", gap: "", words: ["worth", "free", "value"])
    ]

    /// Most frequent complaint and praise themes, plus the biggest gap they imply.
    public static func mineReviews(_ reviews: [Review]) -> (complaints: [String], praises: [String], gap: String?) {
        func rank(_ themes: [Theme], in texts: [String]) -> [(Theme, Int)] {
            themes.map { theme in
                (theme, texts.filter { text in theme.words.contains { text.contains($0) } }.count)
            }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
        }
        let negative = reviews.filter { $0.rating <= 2 }.map { ($0.title + " " + $0.body).lowercased() }
        let positive = reviews.filter { $0.rating >= 4 }.map { ($0.title + " " + $0.body).lowercased() }
        let complaints = rank(complaintThemes, in: negative)
        let praises = rank(praiseThemes, in: positive)
        return (complaints.prefix(3).map(\.0.label), praises.prefix(3).map(\.0.label), complaints.first?.0.gap)
    }

    public static func competitionSummary(competitors: [Competitor], complaints: [String], gap: String?, now: Date) -> String {
        guard !competitors.isEmpty else {
            return "No App Store apps match this search yet. That's rare — the field looks open."
        }
        let strong = competitors.filter { $0.ratingCount >= 1_000 }
        let rated = competitors.filter { $0.ratingCount > 0 }
        let avg = rated.isEmpty ? 0 : rated.map(\.rating).reduce(0, +) / Double(rated.count)
        let stale = competitors.prefix(10).filter { ($0.lastUpdated.map { now.days(since: $0) } ?? 999) > 365 }.count

        var parts: [String] = []
        switch strong.count {
        case 0: parts.append("No strong competitors (none with 1k+ ratings).")
        case 1: parts.append("1 strong competitor: \(strong[0].name).")
        default: parts.append("\(strong.count) strong competitors, led by \(strong.sorted { $0.ratingCount > $1.ratingCount }[0].name).")
        }
        if avg > 0 { parts.append(String(format: "Average rating %.1f★.", avg)) }
        if stale >= 3 { parts.append("\(stale) of the top apps haven't been updated in a year.") }
        if !complaints.isEmpty { parts.append("Users complain about \(complaints.joined(separator: ", ")).") }
        if let gap { parts.append("Gap: \(gap).") }
        return parts.joined(separator: " ")
    }

    // MARK: Difficulty (1–10) and hours

    /// Infers likely features from the keyword so we only ask about the uncertain ones.
    public static func inferredFeatures(for keyword: String) -> [DifficultyFeature: FeatureAnswer] {
        let text = " " + keyword.lowercased() + " "
        var result: [DifficultyFeature: FeatureAnswer] = [:]
        for feature in DifficultyFeature.allCases where feature.hints.contains(where: { text.contains($0) }) {
            result[feature] = .yes
        }
        return result
    }

    public static func difficulty(features: [DifficultyFeature: FeatureAnswer], shippedApps: Int) -> DifficultyEstimate {
        var score = 2.0
        var drivers: [String] = []
        for feature in DifficultyFeature.allCases {
            switch features[feature] {
            case .yes:
                score += feature.weight
                drivers.append(feature.question)
            case .unsure:
                score += feature.weight / 2
            case .no, nil:
                break
            }
        }
        score -= min(1.5, Double(shippedApps) * 0.5)
        let clamped = max(1, min(10, Int(score.rounded())))
        let hours = 20 * pow(1.35, Double(clamped - 1))
        return DifficultyEstimate(
            score: clamped,
            hoursLow: Int((hours * 0.7 / 5).rounded() * 5),
            hoursHigh: Int((hours * 1.4 / 5).rounded() * 5),
            drivers: drivers
        )
    }

    // MARK: Personal fit (0–100)

    public static func fit(tags: [String], profile: UserProfile) -> Int {
        guard !tags.isEmpty else { return 50 }
        let interest = tags.contains { profile.interests.contains($0) } ? 0.25 : 0
        let learned = tags.map { profile.tagWeights[$0] ?? 0 }.reduce(0, +) / Double(tags.count)
        return Int((100 * max(0, min(1, 0.5 + interest + learned * 0.25))).rounded())
    }

    // MARK: Opportunity score (0–100)

    public static func opportunityScore(momentum: Int?, competition: Int?, difficulty: Int?, fit: Int) -> Int {
        let m = Double(momentum ?? 40)
        let c = 100 - Double((competition ?? 5) - 1) / 9 * 100
        let d = 100 - Double((difficulty ?? 5) - 1) / 9 * 100
        return Int((0.35 * m + 0.25 * c + 0.25 * d + 0.15 * Double(fit)).rounded())
    }

    /// Recomputes every derived score on an opportunity.
    public static func rescore(_ opp: inout Opportunity, profile: UserProfile, shippedApps: Int, now: Date) {
        if let trend = opp.trend { opp.momentumScore = momentum(trend) }
        if opp.features.isEmpty { opp.features = inferredFeatures(for: opp.keyword) }
        opp.difficulty = difficulty(features: opp.features, shippedApps: shippedApps)
        opp.opportunityScore = opportunityScore(
            momentum: opp.momentumScore,
            competition: opp.competition?.score,
            difficulty: opp.difficulty?.score,
            fit: fit(tags: opp.tags, profile: profile)
        )
    }

    /// A plain-English one-paragraph summary, used when no AI is configured.
    public static func plainSummary(_ opp: Opportunity) -> String {
        var parts: [String] = []
        if let trend = opp.trend {
            let growth = Int(trend.growthPercent.rounded())
            let sources = trend.mentionsBySource.filter { $0.value > 0 }.keys.sorted().joined(separator: " and ")
            if trend.totalMentions == 0 {
                parts.append("Quiet right now — almost no recent discussion of “\(opp.keyword)”.")
            } else if growth >= 15 {
                parts.append("Interest in “\(opp.keyword)” is up \(growth)% this week\(sources.isEmpty ? "" : " on \(sources)").")
            } else if growth <= -15 {
                parts.append("Interest in “\(opp.keyword)” is cooling (\(growth)% this week).")
            } else {
                parts.append("Steady interest in “\(opp.keyword)” (\(trend.mentionsThisWeek) mentions this week).")
            }
        }
        if let comp = opp.competition { parts.append(comp.summary) }
        if let d = opp.difficulty {
            parts.append("Estimated build: \(d.hoursLow)–\(d.hoursHigh) hours.")
        }
        return parts.joined(separator: " ")
    }
}
