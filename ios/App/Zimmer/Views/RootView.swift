import SwiftUI
import UIKit
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
        .overlay(alignment: .topLeading) { ToastLogElement() }
        // Behind the status bar, where the build strip's gold does not reach.
        .background(Theme.ground.ignoresSafeArea())
        // Here, at the scene's root, rather than on the board: heard whatever is on screen.
        // The poller's state changes here, before the app can be suspended; the reads follow.
        .onChange(of: scenePhase) { _, phase in
            model.sceneChanged(to: phase)
            Task { await model.sceneEntered(phase) }
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
        // Here, with the tabs: it needs them, and a phone scene that opens after the car has left
        // arrives at this the same way as one that was open all along.
        .background { CarHandoverLanding() }
        // Presented from the tabs, not from one screen: the button on any tab opens it.
        .sheet(isPresented: $model.showingQuickRouter) { QuickRouterView() }
        .sheet(isPresented: $model.showingNewSession) { NewSessionView() }
        .sheet(isPresented: $model.showingLive) { LiveHomeView() }
    }
}

/// Takes the phone to a call the car left on it, when `LiveHandover` says so. It asks only while
/// the app is in front, every half second while a route is armed, because a sheet closing is
/// heard by nothing here.
///
/// The half second before the first asking is for a push: a tap on one brings the app forward and
/// arrives a moment later, and what the person tapped goes first.
private struct CarHandoverLanding: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var call = LiveCall.shared
    @State private var keyboardIsUp = false

    private struct Asking: Equatable {
        let route: LiveHandover.Route?
        let inFront: Bool
    }

    var body: some View {
        Color.clear
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardIsUp = true }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardIsUp = false }
            .task(id: Asking(route: call.handover.route, inFront: scenePhase == .active)) {
                guard scenePhase == .active, call.handover.route != nil else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    switch call.handoverStep(inFront: true, screen: screen) {
                    case .nothing: return
                    case .wait: continue
                    case let .land(conversation):
                        model.landOnCall(conversation)
                        return
                    }
                }
            }
    }

    private var screen: LiveHandover.Screen {
        if keyboardIsUp || model.showingQuickRouter || model.showingNewSession { return .busy }
        if model.showingLive {
            guard presentedOverTheTabs <= 1 else { return .busy }
            return model.liveThreadOnScreen.map { .liveThread($0) } ?? .liveList
        }
        return presentedOverTheTabs == 0 ? .free : .busy
    }

    /// Everything presented, whoever presented it: a session page's sheets and dialogs are its
    /// own, and UIKit would refuse a sheet over them, leaving Live's flag set with nothing shown.
    private var presentedOverTheTabs: Int {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var count = 0
        var top = scene?.keyWindow?.rootViewController?.presentedViewController
        while let shown = top {
            count += 1
            top = shown.presentedViewController
        }
        return count
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

/// The board reads itself again every fifteen seconds while it is the screen in front (ten
/// seconds after a read that failed). The web UI's board streams its rows, and a list on a phone
/// that only changes when pulled reads as broken.
///
/// Coming back to the front reads the board at once (`AppModel.sceneEntered`, at the scene's
/// root), and this restarts on that return (`returnsToFront`): a read the phone suspended
/// mid-flight is cancelled rather than waited out, and the clock starts from the fresh read.
///
/// The clock also starts again each time the board is shown, so coming back to the board must
/// read it, or a session trashed meanwhile stays until the interval is up: closing a session's
/// page reads it (`SessionDetailView`'s `sessionChanged`), and choosing the Sessions tab again
/// does (`RootView.tabs`).
private struct BoardPoller: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Color.clear
            .task(id: model.returnsToFront) {
                while !Task.isCancelled {
                    try? await Task.sleep(for: model.freshness.nextPoll)
                    guard !Task.isCancelled else { return }
                    await model.pollBoard()
                }
            }
    }
}
