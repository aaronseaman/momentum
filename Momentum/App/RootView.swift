import SwiftUI
import MomentumKit

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ZStack {
            if model.data.profile.hasOnboarded {
                tabs
            } else {
                OnboardingView()
                    .transition(.opacity)
            }

            if model.isOverwhelmed {
                OverwhelmView()
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
                    .zIndex(2)
            }

            if let run = model.focus {
                FocusView(run: run)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(3)
            }

            ConfettiView(trigger: model.celebrate)
                .ignoresSafeArea()
                .zIndex(4)
        }
        .animation(.easeInOut(duration: 0.25), value: model.isOverwhelmed)
        .animation(.easeInOut(duration: 0.25), value: model.focus)
        .fontDesign(.rounded)
        .sheet(item: $model.focusFinished) { run in
            FocusFinishedSheet(run: run)
                .environment(model)
        }
        #if os(iOS)
        .sheet(isPresented: $model.showSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { model.showSettings = false }
                        }
                    }
            }
            .environment(model)
        }
        #endif
        .sheet(isPresented: $model.showBatch) {
            BatchQuestionsView()
                .environment(model)
        }
    }

    private var tabs: some View {
        @Bindable var model = model
        return TabView(selection: $model.tab) {
            Tab(AppTab.today.title, systemImage: AppTab.today.symbol, value: AppTab.today) {
                NavigationStack { TodayView() }
            }
            Tab(AppTab.radar.title, systemImage: AppTab.radar.symbol, value: AppTab.radar) {
                NavigationStack(path: $model.radarPath) { RadarView() }
            }
            Tab(AppTab.projects.title, systemImage: AppTab.projects.symbol, value: AppTab.projects) {
                NavigationStack(path: $model.projectPath) { ProjectsView() }
            }
            Tab(AppTab.money.title, systemImage: AppTab.money.symbol, value: AppTab.money) {
                NavigationStack { MoneyView() }
            }
            Tab(AppTab.review.title, systemImage: AppTab.review.symbol, value: AppTab.review) {
                NavigationStack { ReviewView() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .overlay(alignment: .bottom) {
            if let banner = model.banner {
                Text(banner)
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.thinMaterial, in: .capsule)
                    .padding(.bottom, 90)
                    .onTapGesture { model.banner = nil }
                    .task {
                        try? await Task.sleep(for: .seconds(4))
                        model.banner = nil
                    }
            }
        }
    }
}
