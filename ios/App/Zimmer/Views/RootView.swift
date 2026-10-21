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
        // Back on the board from another tab: read it, unless it was read moments ago. Here
        // rather than on the board, which another tab may have taken out of the hierarchy.
        .onChange(of: model.tab) { _, tab in
            if tab == .sessions { Task { await model.pollBoard(ifStale: true) } }
        }
        // A link to one of this Zimmer's pages, tapped in a transcript, opens its screen here.
        .environment(\.inAppLinks, model.inAppLinks)
        // Presented from the tabs, not from one screen: the button on any tab opens it.
        .sheet(isPresented: $model.showingQuickRouter) { QuickRouterView() }
        .sheet(isPresented: $model.showingNewSession) { NewSessionView() }
        .sheet(isPresented: $model.showingLive) { LiveHomeView() }
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

/// The board reads itself again every half minute while it is the screen in front (ten seconds
/// after a read that failed), and at once when the app comes back to the front, trying again
/// shortly if that read fails. The web UI's board streams its rows, and a list on a phone that
/// only changes when pulled reads as broken.
///
/// The clock starts again each time the board is shown, so coming back to the board must read
/// it, or a session trashed meanwhile stays until the half minute is up: closing a session's
/// page reads it (`SessionDetailView`'s `sessionChanged`), and choosing the Sessions tab again
/// does (`RootView.tabs`).
private struct BoardPoller: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Color.clear
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: model.freshness.nextPoll)
                    guard !Task.isCancelled else { return }
                    await model.pollBoard()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task {
                    await model.pollBoard()
                    guard model.freshness.lastReadFailed else { return }
                    try? await Task.sleep(for: BoardFreshness.foregroundRetry)
                    await model.pollBoard()
                }
            }
    }
}
