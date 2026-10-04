import SwiftUI
import UniformTypeIdentifiers
import MomentumKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var connecting: IntegrationKind?
    @State private var exporting: ExportDocument?
    @State private var confirmDelete = false
    @State private var claudeKey = ""
    @State private var claudeError: String?
    @State private var savingClaude = false
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            integrations
            research
            ai
            notifications
            focus
            privacy
            about
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .sheet(item: $connecting) { kind in
            ConnectSheet(kind: kind)
                .environment(model)
        }
        .fileExporter(isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
                      document: exporting, contentType: exporting?.contentType ?? .json,
                      defaultFilename: exporting?.filename ?? "Momentum") { _ in exporting = nil }
        .confirmationDialog("Delete all Momentum data?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) { model.deleteEverything() }
        } message: {
            Text("This removes your local database, connected accounts and scheduled notifications from this device. It can't be undone.")
        }
    }

    // MARK: Sections

    private var integrations: some View {
        Section {
            ForEach(IntegrationKind.allCases, id: \.self) { kind in
                let state = model.data.integration(kind)
                HStack(spacing: 12) {
                    Image(systemName: symbol(kind)).frame(width: 24).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.title)
                        if let error = state.lastError, state.isConnected {
                            Text(error).font(.caption).foregroundStyle(Theme.attention)
                        } else if state.isConnected {
                            Text([state.accountLabel, state.lastSyncAt.map { "synced \($0.relativeShort)" }].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(blurb(kind)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if state.isConnected {
                        Button("Disconnect", role: .destructive) { model.disconnect(kind) }
                            .buttonStyle(.borderless)
                    } else {
                        Button("Connect") { connecting = kind }
                            .buttonStyle(.borderless)
                    }
                }
            }
        } header: {
            Text("Integrations")
        } footer: {
            Text("Connect once; Momentum runs from then on. Keys stay in your device's Keychain and go only to the service they belong to.")
        }
    }

    private var research: some View {
        Section("Radar") {
            InterestPicker(selection: Binding(
                get: { model.data.profile.interests },
                set: { new in model.update { $0.profile.interests = new } }
            ))
            Picker("App Store region", selection: binding(\.researchCountry)) {
                ForEach(["us", "gb", "ca", "au", "de", "fr", "es", "it", "nl", "se", "jp", "br", "in", "ph"], id: \.self) { code in
                    Text(Locale.current.localizedString(forRegionCode: code.uppercased()) ?? code.uppercased()).tag(code)
                }
            }
            Toggle("Use Reddit for trend signals", isOn: binding(\.useReddit))
            Toggle("Use Hacker News for trend signals", isOn: binding(\.useHackerNews))
        }
    }

    private var ai: some View {
        Section {
            Picker("Assistant", selection: binding(\.aiMode)) {
                ForEach(AIMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            if model.data.preferences.aiMode == .onDevice && !OnDeviceGenerator.isAvailable {
                Text("Apple Intelligence isn't available on this device, so Momentum uses its built-in rules.")
                    .font(.caption).foregroundStyle(Theme.attention)
            }
            if model.data.preferences.aiMode == .claude {
                if model.hasClaudeKey && claudeKey.isEmpty {
                    LabeledContent("Claude API key", value: "Saved in Keychain")
                }
                SecureField("Claude API key (sk-ant-…)", text: $claudeKey)
                    .textContentType(.password)
                if let claudeError { Text(claudeError).font(.caption).foregroundStyle(Theme.attention) }
                Button(savingClaude ? "Checking…" : "Save key") {
                    savingClaude = true
                    Task {
                        do {
                            try await model.setClaudeKey(claudeKey)
                            claudeKey = ""
                            claudeError = nil
                        } catch {
                            claudeError = (error as? LocalizedError)?.errorDescription ?? "That key didn't work."
                        }
                        savingClaude = false
                    }
                }
                .disabled(claudeKey.isEmpty || savingClaude)
            }
        } header: {
            Text("AI")
        } footer: {
            Text("AI writes friendlier summaries and project steps. Without it, Momentum's built-in rules do the same job more plainly. Claude requests send only project names, stages, issue titles and public market data.")
        }
    }

    private var notifications: some View {
        Section {
            Toggle("Morning brief", isOn: binding(\.morningBrief))
            if model.data.preferences.morningBrief { timePicker("At", \.morningTime) }
            Toggle("Midday check-in", isOn: binding(\.middayCheckIn))
            Toggle("Evening summary", isOn: binding(\.eveningSummary))
            if model.data.preferences.eveningSummary { timePicker("At", \.eveningTime) }
            Toggle("Weekly review (Sundays)", isOn: binding(\.weeklyReview))
            Toggle("Alerts: revenue, builds, App Review, trends", isOn: binding(\.alerts))
            Stepper("Up to \(model.data.preferences.maxQuestionsPerDay) \(model.data.preferences.maxQuestionsPerDay == 1 ? "question" : "questions") a day",
                    value: binding(\.maxQuestionsPerDay), in: 1...3)
            Button("Allow notifications") {
                Task {
                    _ = await model.notifications.requestPermission()
                    await model.notifications.reschedule(model.data)
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Every notification can be answered right from the notification. No badges, ever.")
        }
    }

    private var focus: some View {
        Section("Focus") {
            Picker("Session length", selection: binding(\.focusMinutes)) {
                ForEach([5, 15, 25, 45], id: \.self) { Text("\($0) minutes").tag($0) }
            }
            Toggle("Soft background sound", isOn: binding(\.ambientSound))
            Picker("Preferred focus time", selection: binding(\.focusHour)) {
                ForEach(6..<22, id: \.self) { hour in
                    Text(Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())?.formatted(date: .omitted, time: .shortened) ?? "\(hour):00").tag(hour)
                }
            }
            Toggle("Block focus time on my calendar", isOn: binding(\.calendarBlocking))
            Picker("Ask if a project is stalled after", selection: binding(\.stallDays)) {
                ForEach([5, 7, 8, 10, 14], id: \.self) { Text("\($0) quiet days").tag($0) }
            }
            #if os(macOS)
            Toggle("Open at login (keeps Momentum watching)", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in LaunchAtLogin.set(enabled) }
            #endif
        }
    }

    private var privacy: some View {
        Section {
            Label("Your data lives on this device, encrypted with a key in your Keychain.", systemImage: "lock.shield")
            Label("No accounts, no tracking, no data selling. Ever.", systemImage: "hand.raised")
            Button("Export everything (JSON)") {
                exporting = ExportDocument(data: model.exportJSON(), contentType: .json, filename: "Momentum.json")
            }
            Button("Export spreadsheets (CSV)") {
                exporting = ExportDocument(data: Data(model.exportCSV().utf8), contentType: .commaSeparatedText, filename: "Momentum.csv")
            }
            Button("Delete all data", role: .destructive) { confirmDelete = true }
        } header: {
            Text("Privacy")
        }
    }

    private var about: some View {
        Section {
            LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
            Text("Momentum: your external executive function. You answer a few simple questions; it handles the rest.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Helpers

    private func binding<T>(_ keyPath: WritableKeyPath<Preferences, T>) -> Binding<T> {
        Binding(
            get: { model.data.preferences[keyPath: keyPath] },
            set: { value in model.setPreferences { $0[keyPath: keyPath] = value } }
        )
    }

    private func timePicker(_ title: String, _ keyPath: WritableKeyPath<Preferences, ClockTime>) -> some View {
        DatePicker(title, selection: Binding(
            get: {
                let time = model.data.preferences[keyPath: keyPath]
                return Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
                model.setPreferences { $0[keyPath: keyPath] = ClockTime(hour: comps.hour ?? 8, minute: comps.minute ?? 0) }
            }
        ), displayedComponents: .hourAndMinute)
    }

    private func symbol(_ kind: IntegrationKind) -> String {
        switch kind {
        case .github: "chevron.left.forwardslash.chevron.right"
        case .appStoreConnect: "app.badge"
        case .revenueCat: "arrow.triangle.2.circlepath"
        case .stripe: "creditcard"
        }
    }

    private func blurb(_ kind: IntegrationKind) -> String {
        switch kind {
        case .github: "Tracks commits, builds, releases and issues."
        case .appStoreConnect: "Tracks review status, versions, sales and downloads."
        case .revenueCat: "Adds MRR, subscribers and trials."
        case .stripe: "Adds web income and subscriptions."
        }
    }
}

/// Multi-select chips for interests.
struct InterestPicker: View {
    @Binding var selection: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ideas I'm interested in").font(.subheadline)
            FlowLayout(spacing: 8) {
                ForEach(InterestCatalog.topics, id: \.tag) { topic in
                    let isOn = selection.contains(topic.tag)
                    Button {
                        if isOn { selection.removeAll { $0 == topic.tag } } else { selection.append(topic.tag) }
                    } label: {
                        Text(topic.title)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .foregroundStyle(isOn ? Color.white : Theme.trend)
                            .background(isOn ? Theme.trend : Theme.trend.opacity(0.1), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .commaSeparatedText] }
    var data: Data
    var contentType: UTType
    var filename: String

    init(data: Data, contentType: UTType, filename: String) {
        self.data = data
        self.contentType = contentType
        self.filename = filename
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        contentType = configuration.contentType
        filename = "Momentum"
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
