import SwiftUI
import MomentumKit

struct ProjectsView: View {
    @Environment(AppModel.self) private var model
    @State private var addingProject = false
    @State private var newName = ""

    var body: some View {
        let active = model.data.projects.filter(\.stage.isActive)
            .sorted { Planner.priority(of: $0, data: model.data, now: Date()) > Planner.priority(of: $1, data: model.data, now: Date()) }
        let resting = model.data.projects.filter { !$0.stage.isActive }
        Page {
            if model.data.projects.isEmpty {
                EmptyState(symbol: "square.stack.3d.up",
                           title: "No projects yet",
                           message: "Connect GitHub or App Store Connect and I'll find your projects and track them for you. Or add one by name.",
                           actionTitle: "Add a project") { addingProject = true }
            }
            ForEach(active) { project in
                NavigationLink(value: project.id) {
                    ProjectCard(project: project)
                }
                .buttonStyle(.plain)
            }
            if !resting.isEmpty {
                Text("Resting")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                ForEach(resting) { project in
                    NavigationLink(value: project.id) {
                        ProjectCard(project: project)
                    }
                    .buttonStyle(.plain)
                    .opacity(0.7)
                }
            }
        }
        .navigationTitle("Projects")
        .navigationDestination(for: UUID.self) { id in
            ProjectDetailView(id: id)
        }
        .toolbar {
            CommonToolbar(model: model)
            ToolbarItem(placement: .primaryAction) {
                Button {
                    addingProject = true
                } label: {
                    Label("Add project", systemImage: "plus")
                }
            }
        }
        .refreshable { await model.refresh() }
        .alert("New project", isPresented: $addingProject) {
            TextField("Name", text: $newName)
            Button("Add") {
                model.addProject(named: newName)
                newName = ""
            }
            Button("Cancel", role: .cancel) { newName = "" }
        } message: {
            Text("Just a name. I'll suggest the first tiny steps.")
        }
    }
}

struct ProjectCard: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        let revenue = RevenueAnalytics.total(model.data.revenue, from: DayKey(Date()).adding(days: -29), through: DayKey(Date()), projectID: project.id)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    ProgressRing(progress: project.progress, tint: Theme.color(for: project.stage), lineWidth: 5)
                    Image(systemName: project.symbol)
                        .font(.title3)
                        .foregroundStyle(Theme.color(for: project.stage))
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(project.name).font(.headline)
                        StageBadge(stage: project.stage)
                        if model.data.profile.focusProjectID == project.id {
                            Image(systemName: "scope").font(.caption).foregroundStyle(Color.accentColor)
                                .accessibilityLabel("Focus project")
                        }
                    }
                    Text(activityText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if revenue != 0 {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(MoneyFormat.currency(revenue, code: model.currency, compact: true))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.money)
                        Text("30 days").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if project.stage.isActive, let step = project.openSteps.first {
                HStack(spacing: 10) {
                    Image(systemName: step.source == .signal ? "exclamationmark.circle" : "arrow.right.circle")
                        .foregroundStyle(step.source == .signal ? Theme.attention : .accentColor)
                    Text(step.title).font(.subheadline).lineLimit(2)
                    Spacer(minLength: 0)
                    Text("\(step.minutes)m").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Button {
                        let action = NextAction(title: step.title, minutes: step.minutes, projectID: project.id, projectName: project.name,
                                                stepID: step.id, reason: "", tinyStep: Planner.tinyStep(for: step, projectName: project.name))
                        model.startFocus(action: action)
                    } label: {
                        Label("Start focus", systemImage: "timer")
                    }
                    .buttonStyle(.soft(.accentColor))
                    Button {
                        model.snooze(projectID: project.id, hours: 24)
                    } label: {
                        Label(project.isSnoozed(now: Date()) ? "Snoozed" : "Snooze", systemImage: "moon.zzz")
                    }
                    .buttonStyle(.soft(.secondary))
                    Button {
                        model.imStuck(project.id)
                    } label: {
                        Label("Help", systemImage: "lifepreserver")
                    }
                    .buttonStyle(.soft(Theme.attention))
                }
                .labelStyle(.titleAndIcon)
                .font(.subheadline)
            }
        }
        .card()
        .accessibilityElement(children: .contain)
    }

    private var activityText: String {
        guard let last = project.lastActivityAt else { return "No activity yet" }
        return "Last activity \(last.relativeShort)"
    }
}

struct ProjectDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let id: UUID
    @State private var confirmRemove = false
    @State private var thinking = false

    var body: some View {
        if let project = model.data.project(id) {
            content(project)
        } else {
            EmptyState(symbol: "questionmark", title: "Not found", message: "This project was removed.").padding()
        }
    }

    private func content(_ project: Project) -> some View {
        Page {
            HStack(spacing: 16) {
                ZStack {
                    ProgressRing(progress: project.progress, tint: Theme.color(for: project.stage), lineWidth: 8)
                    Image(systemName: project.symbol).font(.title).foregroundStyle(Theme.color(for: project.stage))
                }
                .frame(width: 76, height: 76)
                VStack(alignment: .leading, spacing: 6) {
                    Text(project.name).font(.largeTitle.weight(.bold))
                    HStack {
                        StageBadge(stage: project.stage)
                        Text(project.stageSource == .user ? "set by you" : "detected automatically")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            stepsCard(project)
            signalsCard(project)
            moneyCard(project)

            VStack(alignment: .leading, spacing: 12) {
                CardLabel(text: "Adjust", symbol: "slider.horizontal.3")
                Text("Momentum updates this automatically. Correct it any time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Stage", selection: Binding(get: { project.stage }, set: { model.setStage(project.id, $0) })) {
                    ForEach(ProjectStage.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Focus project this week", isOn: Binding(
                    get: { model.data.profile.focusProjectID == project.id },
                    set: { model.setFocusProject($0 ? project.id : nil) }
                ))
                Button("Stop tracking this project", role: .destructive) { confirmRemove = true }
                    .buttonStyle(.borderless)
            }
            .card()
        }
        .navigationTitle(project.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .confirmationDialog("Stop tracking \(project.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Stop tracking", role: .destructive) { model.removeProject(project.id) }
        } message: {
            Text("Your code and store data aren't touched. Momentum just stops watching it.")
        }
    }

    private func stepsCard(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CardLabel(text: "Next steps", symbol: "list.bullet", tint: .accentColor)
                Spacer()
                Button {
                    thinking = true
                    Task {
                        await model.refreshSteps(for: project.id)
                        thinking = false
                    }
                } label: {
                    if thinking { ProgressView().controlSize(.small) } else { Label("Suggest new steps", systemImage: "sparkles") }
                }
                .buttonStyle(.borderless)
                .font(.caption.weight(.semibold))
                .disabled(thinking)
            }
            if project.openSteps.isEmpty {
                Text(project.stage.isActive ? "All caught up." : "Resting. Change the stage to pick it back up.")
                    .foregroundStyle(.secondary)
            }
            ForEach(project.openSteps.prefix(6)) { step in
                HStack(spacing: 12) {
                    Button {
                        withAnimation(.snappy) { model.markDone(projectID: project.id, stepID: step.id) }
                    } label: {
                        Image(systemName: "circle").font(.title3).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Mark done: \(step.title)")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title).font(.body)
                        Text("\(step.minutes) min · \(step.energy.title.lowercased()) energy\(step.source == .ai ? " · AI" : "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button {
                        let action = NextAction(title: step.title, minutes: step.minutes, projectID: project.id, projectName: project.name,
                                                stepID: step.id, reason: "", tinyStep: Planner.tinyStep(for: step, projectName: project.name))
                        model.startFocus(action: action)
                    } label: {
                        Image(systemName: "play.circle.fill").font(.title2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Start focus on \(step.title)")
                }
            }
            if project.stage.isActive {
                Button("I'm stuck — break it into tiny steps") { model.imStuck(project.id) }
                    .buttonStyle(.soft(Theme.attention))
            }
        }
        .card()
    }

    private func signalsCard(_ project: Project) -> some View {
        let s = project.signals
        return VStack(alignment: .leading, spacing: 10) {
            CardLabel(text: "What I'm watching", symbol: "eye")
            if let repo = project.links.githubRepo {
                row("chevron.left.forwardslash.chevron.right", "GitHub", "\(repo) · \(s.commitsLast7Days) commits this week")
                if let ci = s.ciStatus {
                    row(ci == .failure ? "xmark.octagon" : "checkmark.circle", "Latest build", ci.rawValue.capitalized,
                        tint: ci == .failure ? Theme.attention : Theme.money, url: s.ciRunURL)
                }
                if !s.openIssues.isEmpty {
                    row("exclamationmark.bubble", "Open issues", "\(s.openIssues.count) (\(s.openIssues.filter(\.isBug).count) bugs)")
                }
                if let tag = s.latestReleaseTag { row("tag", "Latest release", tag) }
            }
            if project.links.appStoreAppID != nil {
                if let live = s.liveVersion { row("app.badge.checkmark", "Live on the App Store", "v\(live)", tint: Theme.money) }
                if let current = s.currentStoreVersion, current.version != s.liveVersion {
                    row("shippingbox", "Version \(current.version)", current.state.rawValue, tint: current.state == .rejected ? Theme.attention : .secondary)
                }
                if let build = s.latestBuildUploadedAt { row("hammer", "Latest build", build.relativeShort) }
            }
            if project.links.githubRepo == nil && project.links.appStoreAppID == nil {
                Text("Not linked to any tool yet. Connect GitHub or App Store Connect in Settings and I'll match it automatically.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private func moneyCard(_ project: Project) -> some View {
        let series = RevenueAnalytics.series(model.data.revenue, days: 30, endingAt: DayKey(Date()).adding(days: -1), projectID: project.id)
        let total = series.map(\.amount).reduce(0, +)
        return Group {
            if total != 0 {
                VStack(alignment: .leading, spacing: 8) {
                    CardLabel(text: "Revenue · 30 days", symbol: "dollarsign.circle", tint: Theme.money)
                    Text(MoneyFormat.currency(total, code: model.currency)).font(.title.weight(.bold)).foregroundStyle(Theme.money)
                    Sparkline(points: series).frame(height: 60)
                }
                .card(tint: Theme.money)
            }
        }
    }

    private func row(_ symbol: String, _ title: String, _ value: String, tint: Color = .secondary, url: String? = nil) -> some View {
        Button {
            if let url = url.flatMap(URL.init(string:)) { openURL(url) }
        } label: {
            HStack {
                Image(systemName: symbol).foregroundStyle(tint).frame(width: 22)
                Text(title).foregroundStyle(.primary)
                Spacer()
                Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
            .font(.subheadline)
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
    }
}
