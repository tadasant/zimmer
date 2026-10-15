import SwiftUI
import ZimmerKit

/// Sign-in gates everything; after it, the tabs: the web UI's top navigation (sessions,
/// notifications, triggers, and costs and health under More).
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            if let badge = AppConfiguration.buildEnvironment.badge {
                BuildBadge(text: badge, summary: model.buildTarget.summary)
            }
            switch model.isSignedIn {
            case .none:
                LoadingState(text: "Opening Zimmer…").background(Theme.ground)
            case .some(false):
                SignInView()
            case .some(true):
                tabs
            }
        }
        // Behind the status bar, where the build strip's gold does not reach.
        .background(Theme.ground.ignoresSafeArea())
        // Signed out at the front: read the Keychain again. A sign-in that a launch in the
        // background could not read comes back here; a real sign-out reads back nothing.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, model.isSignedIn == false { Task { await model.start() } }
        }
    }
}

extension RootView {
    var tabs: some View {
        TabView(selection: $model.tab) {
            NavigationStack(path: $model.path) {
                SessionListView()
                    .background { BoardPoller() }
                    .navigationDestination(for: Int.self) { id in
                        SessionDetailView(id: id, api: model.api)
                    }
            }
            .tabItem { Label("Sessions", systemImage: "rectangle.stack") }
            .tag(AppTab.sessions)

            // The Quick Router sits in the corner of these, and of everything pushed on them
            // (Costs, Health), as the web UI's bubble is on every page. The board has the bar.
            NavigationStack { InboxView() }
                .quickRouterCorner()
                .tabItem { Label("Inbox", systemImage: "bell") }
                .badge(model.unreadCount)
                .tag(AppTab.inbox)

            NavigationStack { TriggersView() }
                .quickRouterCorner()
                .tabItem { Label("Triggers", systemImage: "bolt") }
                .tag(AppTab.triggers)

            NavigationStack { MoreView() }
                .quickRouterCorner()
                .tabItem { Label("More", systemImage: "ellipsis") }
                .tag(AppTab.more)
        }
        // Presented from the tabs, not from one screen: the button on any tab opens it.
        .sheet(isPresented: $model.showingQuickRouter) { QuickRouterView() }
        .sheet(isPresented: $model.showingNewSession) { NewSessionView() }
    }
}

/// A strip that says which deployment a non-production build is for, so a staging screen
/// is never mistaken for the real one: a strip of the mark's gold under the status bar (not
/// behind it, where the status bar's white text would sit on it), its navy in tracked small caps.
struct BuildBadge: View {
    let text: String
    let summary: String

    var body: some View {
        Text(text)
            .themeLabel(size: 10, color: Theme.navy)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(Theme.signatureGold, ignoresSafeAreaEdges: [])
            .accessibilityIdentifier("build.badge")
            .accessibilityValue(summary)
    }
}

/// The board reads itself again every half minute while it is the screen in front, and at
/// once when the app comes back to the front: the web UI's board streams its rows, and a
/// list on a phone that only changes when pulled reads as broken.
private struct BoardPoller: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Color.clear
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else { return }
                    await refreshIfInFront()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await refreshIfInFront() } }
            }
    }

    /// Only the board in front, not one under an open session or another tab, and not while a
    /// selection or a drag is in hand.
    private func refreshIfInFront() async {
        guard model.tab == .sessions, model.path.isEmpty, !model.isEditingBoard else { return }
        await model.refresh(silently: true)
    }
}
