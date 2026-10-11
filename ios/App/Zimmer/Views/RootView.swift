import SwiftUI
import ZimmerKit

/// Sign-in gates everything; after it, the tabs: the web UI's top navigation (sessions,
/// notifications, triggers, and costs and health under More).
struct RootView: View {
    @EnvironmentObject private var model: AppModel

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
    }
}

extension RootView {
    var tabs: some View {
        TabView(selection: $model.tab) {
            NavigationStack(path: $model.path) {
                SessionListView()
                    .navigationDestination(for: Int.self) { id in
                        SessionDetailView(id: id, api: model.api)
                    }
            }
            .tabItem { Label("Sessions", systemImage: "rectangle.stack") }
            .tag(AppTab.sessions)

            NavigationStack { InboxView() }
                .tabItem { Label("Inbox", systemImage: "bell") }
                .badge(model.unreadCount)
                .tag(AppTab.inbox)

            NavigationStack { TriggersView() }
                .tabItem { Label("Triggers", systemImage: "bolt") }
                .tag(AppTab.triggers)

            NavigationStack { MoreView() }
                .tabItem { Label("More", systemImage: "ellipsis") }
                .tag(AppTab.more)
        }
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
