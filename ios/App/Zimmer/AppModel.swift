import AuthenticationServices
import Foundation
import SwiftUI
import ZimmerKit
import os

/// The state the screens render. It holds no networking rules and no sign-in rules — those
/// are ZimmerKit's — only what is on screen and the calls that change it.
@MainActor
final class AppModel: ObservableObject {
    /// Nil until the stored sign-in has been read.
    @Published private(set) var isSignedIn: Bool?
    @Published var filter: SessionFilter = .needsInput
    /// The board view: Your board, Last Touched, Created or Ranked. Remembered, as the web UI
    /// remembers it in a cookie; "Last Touched" by default, the web UI's default on a phone.
    @Published var view: BoardView = BoardView(rawValue: UserDefaults.standard.string(forKey: "boardView") ?? "") ?? .lastTouched {
        didSet { UserDefaults.standard.set(view.rawValue, forKey: "boardView") }
    }
    /// The board-visibility filter; "On board" by default, as on the web UI's board.
    @Published private(set) var board: BoardFilter = .onBoard
    /// The search box. Empty means the plain list.
    @Published var searchText = ""
    @Published var searchScope: SearchScope = .titles
    /// True when the list is not everything the filters matched: a transcript search that
    /// stopped early, or more sessions than the newest five pages.
    @Published private(set) var listIncomplete = false
    /// A one-line confirmation of the last row action ("Snoozed until …").
    @Published var notice: String?
    @Published private(set) var sessions: [SessionSummary] = []
    @Published private(set) var isLoading = false
    @Published var error: ZimmerError?
    @Published private(set) var signedInOrigins: ServerOrigins?
    /// When the edge's credential expires, on a deployment that has one.
    @Published private(set) var edgeExpiry: Date?
    /// The navigation stack: session ids, so a push or a deep link can open one.
    @Published var path: [Int] = []
    @Published var showingQuickRouter = false

    let environment: AppEnvironment
    private let log = Logger(subsystem: "com.tadasant.zimmer", category: "app")

    init(environment: AppEnvironment = .shared) {
        self.environment = environment
    }

    private var connection: AppEnvironment.Connection { environment.connection }

    var buildTarget: BuildTarget { environment.configuration.buildTarget(signedInTo: signedInOrigins) }
    var hasEdge: Bool { connection.edge != nil }
    var api: ZimmerAPI { connection.api }

    func start() async {
        let signIn = await connection.auth.signIn
        signedInOrigins = signIn?.origins
        isSignedIn = signIn != nil
        guard signIn != nil else { return }
        // Renew the edge's credential ahead of its expiry rather than on a refused call.
        if let edge = connection.edge, await edge.needsLogin() {
            await signInToEdge()
        }
        await refreshEdgeExpiry()
        await refresh()
        openFixtureScreen()
        if !environment.isFixture { await PushCoordinator.shared.enable() }
    }

    /// `#if DEBUG` launch arguments that open a screen `simctl` cannot tap its way to,
    /// so `ios/bin/ui-test` can photograph it.
    private func openFixtureScreen() {
        #if DEBUG
        guard environment.isFixture else { return }
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "-ZimmerFixtureOpenSession"),
           arguments.indices.contains(flag + 1), let id = Int(arguments[flag + 1]) {
            path = [id]
        }
        if arguments.contains("-ZimmerFixtureQuickRouter") { showingQuickRouter = true }
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        // Every fixture launch starts from the default view, whatever an earlier run chose.
        view = value("-ZimmerFixtureView").flatMap(BoardView.init(rawValue:)) ?? .lastTouched
        let listFilter = value("-ZimmerFixtureFilter").flatMap(SessionFilter.init(rawValue:))
        let listBoard = value("-ZimmerFixtureBoard").flatMap(BoardFilter.init(rawValue:))
        if listFilter != nil || listBoard != nil {
            filter = listFilter ?? filter
            board = listBoard ?? board
            Task { await refresh() }
        }
        // The list's search box picks this up and searches, as if typed.
        if let search = value("-ZimmerFixtureSearch") { searchText = search }
        #endif
    }

    /// An error raised on another screen that the whole app has to act on: a sign-in
    /// that ended returns to the sign-in screen. Others stay on the screen that hit them.
    func noteError(_ error: ZimmerError) {
        if error == .unauthorized { handle(error) }
    }

    /// A session left the list's filter (archived) or joined it (started).
    func sessionChanged() async {
        await refresh()
    }

    /// Start a Quick Router session and open it.
    func startQuickRouter(_ prompt: String) async -> Bool {
        do {
            let id = try await connection.api.startQuickRouter(prompt)
            showingQuickRouter = false
            path.append(id)
            await refresh()
            return true
        } catch {
            handle(error)
            return false
        }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        let requested = filter
        let board = board
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = searchScope
        do {
            let result: SessionSearchResult
            if query.isEmpty {
                result = try await connection.api.sessions(requested, board: board, view: view)
            } else {
                result = try await connection.api.search(query, contents: scope == .transcripts, filter: requested, board: board)
            }
            guard requested == filter, board == self.board, query == searchText.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            sessions = result.sessions
            listIncomplete = !result.complete
            error = nil
        } catch {
            handle(error)
        }
        await refreshEdgeExpiry()
    }

    func select(_ filter: SessionFilter) async {
        guard filter != self.filter else { return }
        self.filter = filter
        sessions = []
        await refresh()
    }

    func select(_ board: BoardFilter) async {
        guard board != self.board else { return }
        self.board = board
        sessions = []
        await refresh()
    }

    /// One action on one session from the list (a swipe or a long press): the server's answer
    /// replaces the row, and a row that no longer belongs on this list leaves it.
    @discardableResult
    func perform(_ done: String, on id: Int, _ action: (ZimmerAPI) async throws -> SessionSummary) async -> Bool {
        do {
            let updated = try await action(connection.api)
            withAnimation {
                if let index = sessions.firstIndex(where: { $0.id == id }) {
                    if belongsOnList(updated) { sessions[index] = updated } else { sessions.remove(at: index) }
                }
            }
            notice = done
            error = nil
            Haptics.success()
            return true
        } catch {
            handle(error)
            Haptics.failure()
            return false
        }
    }

    private func belongsOnList(_ session: SessionSummary) -> Bool {
        filter.admits(session.status) && board.admits(session)
    }

    /// The rows in the current view's order and sections.
    var sections: [BoardSection] { view.sections(sessions) }

    /// Trash the selected sessions. Each refusal is shown with the server's reason; the rest go.
    func trash(_ ids: Set<Int>) async {
        do {
            let result = try await connection.api.bulkArchive(Array(ids).sorted())
            await refresh()
            // After the refresh, which clears the banner: the refusals are what it is for.
            let refused = result.errors.map { "#\($0.id): \($0.message)" }
            notice = "Moved \(result.archivedCount) to trash" + (refused.isEmpty ? "" : "; \(refused.count) refused")
            if !refused.isEmpty { error = .http(status: 422, message: refused.joined(separator: "\n")) }
            if refused.isEmpty { Haptics.success() } else { Haptics.failure() }
        } catch {
            handle(error)
            Haptics.failure()
        }
    }

    func refreshAll() async {
        do {
            let summary = try await connection.api.refreshAll()
            await refresh()
            notice = summary
            Haptics.success()
        } catch {
            handle(error)
            Haptics.failure()
        }
    }

    /// The Ranked view's *Start now*.
    func startNow(_ id: Int) async {
        do {
            notice = try await connection.api.startNow(id)
            Haptics.success()
            await refresh()
        } catch {
            handle(error)
            Haptics.failure()
        }
    }

    /// The Ranked view's drag-and-drop, then the queue as the server now ranks it.
    func reorder(_ id: Int, above: Int?, below: Int?) async {
        do {
            _ = try await connection.api.reorder(id, above: above, below: below)
            notice = "Moved in the spot queue"
            Haptics.success()
        } catch {
            handle(error)
            Haptics.failure()
        }
        await refresh()
    }

    /// The web UI's page for a session, for what the app does not do itself.
    func webURL(for id: Int) -> URL? {
        guard let web = signedInOrigins?.web else { return nil }
        return ServerURL.join(web, "/sessions/\(id)")
    }

    /// Sign in to a deployment: the edge first when machine calls go to a separate app
    /// host (its credential has to ride on the token call), then Zimmer's own OAuth.
    func signIn(web rawWeb: String, api rawAPI: String) async {
        guard let web = ServerURL.parse(rawWeb) else {
            error = .signIn("Enter the https address of your Zimmer, like https://zimmer.example.com.")
            return
        }
        let trimmedAPI = rawAPI.trimmingCharacters(in: .whitespaces)
        let api = trimmedAPI.isEmpty ? nil : ServerURL.parse(trimmedAPI)
        if !trimmedAPI.isEmpty && api == nil {
            error = .signIn("The app host must be an https address too, or left empty.")
            return
        }
        let origins = ServerOrigins(web: web, api: api)
        let connection = environment.connect(to: origins)
        do {
            if let edge = connection.edge, await edge.needsLogin() {
                try await edge.login()
            }
            let flow = OAuthSignIn(origins: origins)
            let callback = try await WebAuthPresenter.shared.present(flow.authorizeURL)
            try await connection.auth.complete(flow, callback: callback)
            environment.configuration.remember(origins)
            log.info("signed in to \(origins.web.host ?? "?", privacy: .public) via \(origins.api.host ?? "?", privacy: .public)")
            error = nil
            await start()
        } catch let authError as ASWebAuthenticationSessionError where authError.code == .canceledLogin {
            log.info("sign-in sheet cancelled")
        } catch {
            handle(error)
        }
    }

    /// Run the edge's handoff again — proactively near expiry, or after a refusal.
    func signInToEdge() async {
        guard let edge = connection.edge else { return }
        do {
            try await edge.login()
            if error == .edgeRefused { error = nil }
        } catch let authError as ASWebAuthenticationSessionError where authError.code == .canceledLogin {
            log.info("edge sign-in sheet cancelled")
        } catch {
            handle(error)
        }
        await refreshEdgeExpiry()
    }

    func signOut() async {
        await PushCoordinator.shared.unregister()
        await connection.auth.signOut()
        await connection.edge?.forget()
        sessions = []
        signedInOrigins = nil
        edgeExpiry = nil
        isSignedIn = false
    }

    private func refreshEdgeExpiry() async {
        guard let edge = connection.edge else { edgeExpiry = nil; return }
        let token = await edge.headers()["cf-access-token"]
        edgeExpiry = token.flatMap(CloudflareAccessCredential.expiry(of:))
    }

    private func handle(_ error: Error) {
        let zimmerError = error as? ZimmerError ?? .transport(error)
        log.error("request failed: \(String(describing: zimmerError), privacy: .public)")
        if zimmerError == .unauthorized {
            isSignedIn = false
            sessions = []
        }
        self.error = zimmerError
    }
}
