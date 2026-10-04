import Foundation
import UserNotifications
import MomentumKit

/// Local notifications only. Every notification is answerable without opening the app.
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    enum Action {
        case answer(questionID: UUID, optionID: String)
        case startFocus
        case snoozeFocus(title: String, body: String)
        case planTomorrow
        case open(questionID: UUID?)
    }

    /// Delivered on the main actor.
    var onAction: (@MainActor (Action) -> Void)?

    private let center = UNUserNotificationCenter.current()
    private static let briefPrefix = "brief."

    override init() {
        super.init()
        center.delegate = self
    }

    func requestPermission() async -> Bool {
        // No badges: Momentum never shows red counters.
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func isAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    // MARK: Categories

    private static let focusCategory: UNNotificationCategory = {
        let start = UNNotificationAction(identifier: "focus.start", title: "Start focus", options: [.foreground])
        let snooze = UNNotificationAction(identifier: "focus.snooze", title: "Snooze 30 min", options: [])
        let skip = UNNotificationAction(identifier: "focus.skip", title: "Skip", options: [])
        return UNNotificationCategory(identifier: "focus", actions: [start, snooze, skip], intentIdentifiers: [], options: [])
    }()

    private static let planCategory: UNNotificationCategory = {
        let yes = UNNotificationAction(identifier: "plan.yes", title: "Yes", options: [])
        let no = UNNotificationAction(identifier: "plan.no", title: "No", options: [])
        return UNNotificationCategory(identifier: "plan", actions: [yes, no], intentIdentifiers: [], options: [])
    }()

    private static func category(for question: Question) -> UNNotificationCategory {
        let actions = question.options.prefix(4).map {
            UNNotificationAction(identifier: "answer.\($0.id)", title: $0.label, options: [])
        }
        return UNNotificationCategory(identifier: "q.\(question.id.uuidString)", actions: actions, intentIdentifiers: [], options: [])
    }

    // MARK: Scheduling

    /// Rebuilds all scheduled briefs from current data. Cheap; call after every change that matters.
    func reschedule(_ data: MomentumData, now: Date = Date()) async {
        guard await isAuthorized() else { return }
        let prefs = data.preferences
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(Self.briefPrefix) })

        var categories: Set<UNNotificationCategory> = [Self.focusCategory, Self.planCategory]
        let question = QuestionEngine.current(data, now: now)
        if let question { categories.insert(Self.category(for: question)) }
        center.setNotificationCategories(categories)

        if prefs.morningBrief, let date = nextDate(prefs.morningTime, after: now) {
            let brief = Briefs.morning(data, now: date)
            await add("brief.morning", brief.title, brief.body, at: date, category: question.map { "q.\($0.id.uuidString)" }, questionID: question?.id)
        }
        if prefs.middayCheckIn, let date = nextDate(prefs.middayTime, after: now), let brief = Briefs.midday(data, now: date) {
            await add("brief.midday", brief.title, brief.body, at: date, category: "focus")
        }
        if prefs.eveningSummary, !data.activeProjects.isEmpty, let date = nextDate(prefs.eveningTime, after: now) {
            let brief = Briefs.evening(data, now: date)
            await add("brief.evening", brief.title, brief.body, at: date, category: "plan")
        }
        if prefs.weeklyReview, let date = nextWeekly(prefs, after: now) {
            let brief = Briefs.weekly(data, now: date)
            await add("brief.weekly", brief.title, brief.body, at: date, category: nil)
        }
    }

    func post(_ alerts: [AlertEvent], data: MomentumData) async {
        guard data.preferences.alerts, !alerts.isEmpty, await isAuthorized() else { return }
        var categories = await center.notificationCategories()
        for alert in alerts.prefix(3) {
            var categoryID: String?
            if let qid = alert.questionID, let question = data.questions.first(where: { $0.id == qid }) {
                let category = Self.category(for: question)
                categories.insert(category)
                categoryID = category.identifier
            }
            center.setNotificationCategories(categories)
            await add("alert.\(UUID().uuidString)", alert.title, alert.body, at: nil, category: categoryID, questionID: alert.questionID)
        }
    }

    /// A gentle nudge at a planned focus time (from "tomorrow's plan" or a snooze).
    func scheduleFocusPrompt(title: String, body: String, at date: Date) async {
        await add("focus.\(Int(date.timeIntervalSince1970))", title, body, at: date, category: "focus")
    }

    func scheduleFocusEnd(at date: Date, title: String) async {
        cancelFocusEnd()
        await add("focusend", "Time's up", "Nice work on “\(title)”. Come back to mark it done.", at: date, category: nil)
    }

    func cancelFocusEnd() {
        center.removePendingNotificationRequests(withIdentifiers: ["focusend"])
    }

    func removeAll() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    private func add(_ id: String, _ title: String, _ body: String, at date: Date?, category: String?, questionID: UUID? = nil) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .active
        if let category { content.categoryIdentifier = category }
        if let questionID { content.userInfo = ["questionID": questionID.uuidString] }
        var trigger: UNNotificationTrigger?
        if let date {
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        }
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    private func nextDate(_ time: ClockTime, after now: Date) -> Date? {
        Calendar.current.nextDate(after: now, matching: DateComponents(hour: time.hour, minute: time.minute), matchingPolicy: .nextTime)
    }

    private func nextWeekly(_ prefs: Preferences, after now: Date) -> Date? {
        Calendar.current.nextDate(after: now, matching: DateComponents(hour: prefs.weeklyReviewTime.hour, minute: prefs.weeklyReviewTime.minute, weekday: prefs.weeklyReviewWeekday), matchingPolicy: .nextTime)
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        let questionID = (content.userInfo["questionID"] as? String).flatMap(UUID.init(uuidString:))
        let identifier = response.actionIdentifier
        let action: Action?
        if identifier.hasPrefix("answer."), let questionID {
            action = .answer(questionID: questionID, optionID: String(identifier.dropFirst("answer.".count)))
        } else if identifier.hasPrefix("answer."), content.categoryIdentifier.hasPrefix("q."),
                  let qid = UUID(uuidString: String(content.categoryIdentifier.dropFirst(2))) {
            action = .answer(questionID: qid, optionID: String(identifier.dropFirst("answer.".count)))
        } else {
            switch identifier {
            case "focus.start": action = .startFocus
            case "focus.snooze": action = .snoozeFocus(title: content.title, body: content.body)
            case "plan.yes": action = .planTomorrow
            case "focus.skip", "plan.no", UNNotificationDismissActionIdentifier: action = nil
            default: action = .open(questionID: questionID)
            }
        }
        guard let action else { return }
        await MainActor.run { [weak self] in self?.onAction?(action) }
    }
}
