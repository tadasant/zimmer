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
    /// What the list is narrowed to — statuses, scheduling class, agent root, genesis — all
    /// combining, as the web UI's filter form does. Remembered, as the web UI remembers its
    /// filters in a cookie.
    @Published private(set) var filters: BoardFilters = AppModel.stored("boardFilters") ?? .default {
        didSet { AppModel.store(filters, "boardFilters") }
    }
    /// The filter sheet (the funnel on the chip row).
    @Published var showingFilters = false
    /// The catalog's agent roots and geneses, for the filter sheet's pickers; read once.
    @Published private(set) var filterOptions: AppConfigs?
    /// The board view: Your board, Last Touched, Created or Ranked. Remembered, as the web UI
    /// remembers it in a cookie; "Last Touched" by default, the web UI's default on a phone.
    @Published var view: BoardView = BoardView(rawValue: UserDefaults.standard.string(forKey: "boardView") ?? "") ?? .lastTouched {
        didSet { UserDefaults.standard.set(view.rawValue, forKey: "boardView") }
    }
    /// The board-visibility filter; "On board" by default, as on the web UI's board.
    @Published private(set) var board: BoardFilter = BoardFilter(rawValue: UserDefaults.standard.string(forKey: "boardVisibility") ?? "") ?? .onBoard {
        didSet { UserDefaults.standard.set(board.rawValue, forKey: "boardVisibility") }
    }
    /// The search box. Empty means the plain list.
    @Published var searchText = ""
    @Published var searchScope: SearchScope = .titles
    /// True when the list is not everything the filters matched: a transcript search that
    /// stopped early, or more sessions than the newest five pages.
    @Published private(set) var listIncomplete = false
    /// A one-line confirmation of the last row action ("Snoozed until …").
    @Published var notice: String?
    /// The session just trashed, while *Undo* is offered for it.
    @Published var undoable: SessionSummary?
    /// A trash refused because messages are queued for the session: asked again, naming the
    /// discard, before it goes.
    @Published var queuedTrash: SessionSummary?
    @Published private(set) var sessions: [SessionSummary] = []
    @Published private(set) var isLoading = false
    @Published var error: ZimmerError?
    @Published private(set) var signedInOrigins: ServerOrigins?
    /// When the edge's credential expires, on a deployment that has one.
    @Published private(set) var edgeExpiry: Date?
    /// The navigation stack: session ids, so a push or a deep link can open one.
    @Published var path: [Int] = [] {
        // Opening a session from anywhere (a push, the inbox, a trigger) shows the Sessions tab.
        didSet {
            if !path.isEmpty, tab != .sessions { tab = .sessions }
            // A session opened from a push or a notification has usually just been read.
            if !path.isEmpty { Task { await refreshUnreadCount() } }
        }
    }
    /// The tab bar: the web UI's top navigation, as iOS tabs.
    @Published var tab: AppTab = .sessions
    /// Unread notifications, for the Inbox tab's badge.
    @Published var unreadCount = 0
    @Published var showingQuickRouter = false
    /// The board is in select or reorder mode: a refresh then would move rows under a finger.
    var isEditingBoard = false
    /// The session the Quick Router was opened from, so the new one threads under it, as
    /// the web bubble on a session page sends `parent_session_id`.
    var quickRouterParent: Int?
    /// The screen the Quick Router was opened on, as the web bubble sends the page it was typed
    /// on: a session's page, with its web URL and title. Nil from the board and the tabs.
    var quickRouterPage: QuickRouterPage?
    /// Words typed in the board's bar, carried into the sheet when it is opened for more. `nil`
    /// when the sheet was opened from anywhere else.
    var quickRouterDraft: String?
    /// What the bar holds once the sheet it opened has closed: empty after a start, the sheet's
    /// words after a Cancel. Set only then, so typing in the bar publishes nothing.
    @Published var quickRouterBarHandback: String?
    /// The full new-session form (the pencil in the Sessions toolbar).
    @Published var showingNewSession = false
    /// Live Mode / Live Voice (LiveHomeView), from the session list's waveform button.
    @Published var showingLive = false
    /// Debug fixture: the live conversation LiveHomeView opens straight into.
    var fixtureLiveConversation: Int?
    /// `-ZimmerFixtureAttachment`: the opened session's composer starts with a file attached,
    /// since a UI test cannot drive the system photo and file pickers.
    var fixtureAttachesFile = false
    /// `-ZimmerFixtureOpenPrompt`: the opened session shows its first prompt's form, once.
    var fixtureOpensPrompt = false
    /// `-ZimmerFixtureCustomSnooze`: the opened session's custom snooze sheet starts open, so
    /// `ios/bin/ui-test` can photograph the date picker.
    var fixtureOpensCustomSnooze = false
    /// `-ZimmerFixtureCatalog <kind>`: the opened session's editor for one kind of artifact
    /// (`mcpServers`, `skills`, `hooks`, `plugins`) starts open, so `ios/bin/ui-test` can
    /// photograph the checklist.
    var fixtureOpensCatalog: CatalogKind?
    /// `-ZimmerFixtureOpenPanels`: the opened session starts at its details card with the
    /// hierarchy and the human messages open, so `ios/bin/ui-test` can photograph them.
    var fixtureOpensPanels = false
    /// `-ZimmerFixtureSlash`: the opened session's composer starts with "/" typed, so
    /// `ios/bin/ui-test` can photograph the skills it offers.
    var fixtureTypesSlash = false
    /// `-ZimmerFixtureSection <section>`: the opened session's page jumps to that section of
    /// its strip (`hierarchy`, `humanMessages`), as a tap on its chip does.
    var fixtureSection: SessionPageSection?
    /// `-ZimmerFixtureFullScreen`: the opened session's transcript opens full screen.
    var fixtureOpensFullScreen = false
    /// `-ZimmerFixtureTrigger <id>`: the Triggers tab opens on that trigger's page.
    @Published var fixtureTrigger: Int?
    /// `-ZimmerFixtureCosts [agent root]`: More opens on Costs, narrowed to the root if one
    /// is named.
    @Published var fixtureCosts: CostScope?
    /// `-ZimmerFixtureHealth`: More opens on Health.
    @Published var fixtureHealth = false
    /// `-ZimmerFixtureClis`: More opens on CLIs.
    @Published var fixtureClis = false
    /// Tools not installed or not signed in: the badge on the board's CLIs button on the web,
    /// here on the More row. Read when More comes to the front; a hint, never an error.
    @Published var cliIssues = 0
    /// `-ZimmerFixtureRunNow`: the opened trigger's Run Now sheet starts open, so
    /// `ios/bin/ui-test` can photograph its variable fields.
    var fixtureOpensRunNow = false
    /// What the web layout announces on every page: queue recovery mode and degraded egress.
    /// Read from the health report, which is the one route the app's token opens for it, so
    /// it is re-read at most every few minutes rather than with every board refresh.
    @Published var systemBanners = SystemBanners()
    private var bannersCheckedAt: Date?

    let environment: AppEnvironment
    private let log = Logger(subsystem: "com.tadasant.zimmer", category: "app")

    init(environment: AppEnvironment = .shared) {
        self.environment = environment
    }

    private var connection: AppEnvironment.Connection { environment.connection }

    var buildTarget: BuildTarget { environment.configuration.buildTarget(signedInTo: signedInOrigins) }
    var hasEdge: Bool { connection.edge != nil }
    var api: ZimmerAPI { connection.api }

    /// Read the sign-in and, when there is one, load the board. Run at launch and again each
    /// time the app comes to the front signed out, because a launch-time Keychain read can
    /// fail (a push before the phone's first unlock) and that is not a sign-out.
    func start() async {
        let signIn = await connection.auth.signIn
        // The connection was built from a Keychain read at launch; when that read failed it
        // was built for no deployment, and an edge in front of this one would be missing.
        if let origins = signIn?.origins { environment.resume(origins) }
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
        // Drafts outlive a launch by design; every fixture launch starts without any, so one
        // test's words never appear in another's composer.
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("draft.") {
            UserDefaults.standard.removeObject(forKey: key)
        }
        if let flag = arguments.firstIndex(of: "-ZimmerFixtureOpenSession"),
           arguments.indices.contains(flag + 1), let id = Int(arguments[flag + 1]) {
            path = [id]
        }
        if arguments.contains("-ZimmerFixtureQuickRouter") {
            // Opened on a session's page, the sheet carries that page, as the corner button does.
            if let id = path.first {
                Task {
                    if let session = try? await connection.api.session(id).session { openQuickRouter(from: session) }
                }
            } else {
                showingQuickRouter = true
            }
        }
        if arguments.contains("-ZimmerFixtureNewSession") { showingNewSession = true }
        // Live: the home sheet, or straight into one conversation's thread.
        if arguments.contains("-ZimmerFixtureLiveHome") { showingLive = true }
        if let flag = arguments.firstIndex(of: "-ZimmerFixtureLiveConversation"),
           arguments.indices.contains(flag + 1), let id = Int(arguments[flag + 1]) {
            fixtureLiveConversation = id
            showingLive = true
        }
        fixtureAttachesFile = arguments.contains("-ZimmerFixtureAttachment")
        fixtureOpensPrompt = arguments.contains("-ZimmerFixtureOpenPrompt")
        fixtureOpensCustomSnooze = arguments.contains("-ZimmerFixtureCustomSnooze")
        fixtureOpensPanels = arguments.contains("-ZimmerFixtureOpenPanels")
        fixtureTypesSlash = arguments.contains("-ZimmerFixtureSlash")
        fixtureOpensFullScreen = arguments.contains("-ZimmerFixtureFullScreen")
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        // Every fixture launch starts from the default view, whatever an earlier run chose.
        view = value("-ZimmerFixtureView").flatMap(BoardView.init(rawValue:)) ?? .lastTouched
        // And from the default filters, whatever an earlier run remembered.
        let listFilter = value("-ZimmerFixtureFilter").flatMap(SessionFilter.init(rawValue:))
        filters = listFilter?.filters ?? .default
        if let statuses = value("-ZimmerFixtureStatuses") {
            filters.statuses = Set(statuses.split(separator: ",").map(String.init))
        }
        if let root = value("-ZimmerFixtureAgentRoot") { filters.agentRoot = root }
        if let klass = value("-ZimmerFixtureClass") { filters.schedulingClass = klass }
        board = value("-ZimmerFixtureBoard").flatMap(BoardFilter.init(rawValue:)) ?? .onBoard
        if arguments.contains("-ZimmerFixtureFilterSheet") { showingFilters = true }
        fixtureOpensCatalog = value("-ZimmerFixtureCatalog").flatMap(CatalogKind.init(rawValue:))
        fixtureSection = value("-ZimmerFixtureSection").flatMap(SessionPageSection.init(rawValue:))
        Task { await refresh() }
        // The list's search box picks this up and searches, as if typed.
        if let search = value("-ZimmerFixtureSearch") { searchText = search }
        if let tab = value("-ZimmerFixtureTab").flatMap(AppTab.init(rawValue:)) { self.tab = tab }
        if let trigger = value("-ZimmerFixtureTrigger").flatMap(Int.init) {
            fixtureTrigger = trigger
            tab = .triggers
        }
        if let flag = arguments.firstIndex(of: "-ZimmerFixtureCosts") {
            // The next argument is a root to narrow to, unless it is the next flag.
            let root = arguments.indices.contains(flag + 1) && !arguments[flag + 1].hasPrefix("-") ? arguments[flag + 1] : nil
            fixtureCosts = root.map(CostScope.agentRoot) ?? .fleet
            tab = .more
        }
        if arguments.contains("-ZimmerFixtureHealth") {
            fixtureHealth = true
            tab = .more
        }
        if arguments.contains("-ZimmerFixtureClis") {
            fixtureClis = true
            tab = .more
        }
        fixtureOpensRunNow = arguments.contains("-ZimmerFixtureRunNow")
        // Trash a session as a swipe would: the Undo toast, or for one with messages queued,
        // the question before they are discarded.
        if let id = value("-ZimmerFixtureTrash").flatMap(Int.init) {
            Task {
                guard let session = try? await connection.api.session(id).session else { return }
                await trash(session)
            }
        }
        #endif
    }

    private static func stored<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private static func store<T: Encodable>(_ value: T, _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
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

    /// Start a session from the full form. The caller opens it.
    func createSession(_ request: NewSessionRequest) async -> SessionSummary? {
        do {
            let session = try await connection.api.createSession(request)
            Haptics.success()
            await refresh()
            return session
        } catch {
            handle(error)
            Haptics.failure()
            return nil
        }
    }

    /// Open the Quick Router sheet. `parent` is the session it was opened on and `page` that
    /// session's page; `draft` is the board bar's words, given only by the bar.
    func openQuickRouter(parent: Int? = nil, page: QuickRouterPage? = nil, draft: String? = nil) {
        quickRouterParent = parent
        quickRouterPage = page
        quickRouterDraft = draft
        showingQuickRouter = true
    }

    /// The Quick Router from a session's page: the page is that session's, by its web URL, as
    /// the bubble reads `window.location`.
    func openQuickRouter(from session: SessionSummary) {
        openQuickRouter(parent: session.id, page: QuickRouterPage.session(session, url: webURL(for: session.id)))
    }

    /// Start a Quick Router session and open it.
    func startQuickRouter(_ prompt: String) async -> Bool {
        await startQuickRouter(QuickRouterRequest(prompt: prompt))
    }

    /// Start a Quick Router session with the sheet's choices and open it — or, with `open`
    /// off, the web bubble's plain *Submit*: the session starts and this screen stays.
    func startQuickRouter(_ request: QuickRouterRequest, open: Bool = true) async -> Bool {
        do {
            let id = try await connection.api.startQuickRouter(request)
            showingQuickRouter = false
            quickRouterParent = nil
            quickRouterPage = nil
            if open {
                path.append(id)
            } else {
                notice = "Started session #\(id) in the background"
                Haptics.success()
            }
            await refresh()
            return true
        } catch {
            handle(error)
            return false
        }
    }

    /// `silently`: a read the board makes on its own — no loading state, and a failure other
    /// than a sign-in that ended is not shown; the next read tries again.
    func refresh(silently: Bool = false) async {
        if !silently { isLoading = true }
        defer { if !silently { isLoading = false } }
        let requested = effectiveFilters
        let board = board
        let view = view
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = searchScope
        do {
            let result: SessionSearchResult
            if query.isEmpty {
                result = try await connection.api.sessions(requested, board: board, view: view)
            } else {
                result = try await connection.api.search(query, contents: scope == .transcripts, filters: requested, board: board)
            }
            // A slower answer to an older request must not overwrite a newer list.
            guard requested == effectiveFilters, board == self.board, view == self.view,
                  query == searchText.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            sessions = result.sessions
            listIncomplete = !result.complete
            error = nil
        } catch {
            if !silently || (error as? ZimmerError) == .unauthorized { handle(error) }
        }
        await refreshEdgeExpiry()
        await refreshUnreadCount()
        await refreshSystemBanners()
    }

    /// The site-wide banners, re-read when the last reading is older than `every`. The
    /// Health screen passes its own fresh report instead of reading twice.
    func refreshSystemBanners(every interval: TimeInterval = 300) async {
        if let checked = bannersCheckedAt, Date().timeIntervalSince(checked) < interval { return }
        // Stamped before the read, so a failing health endpoint — the heaviest one, slowest
        // during the incidents these banners are for — is asked once an interval, not on
        // every poll and pull until it answers.
        bannersCheckedAt = Date()
        // A hint on the board, never a reason to show an error over it.
        guard let report = try? await connection.api.health() else { return }
        note(report)
    }

    func note(_ report: HealthReport) {
        bannersCheckedAt = Date()
        systemBanners = report.banners
    }

    func refreshCliIssues() async {
        if let report = try? await connection.api.cliStatus() { cliIssues = report.unauthenticatedCount }
    }

    func refreshUnreadCount() async {
        // The badge is a hint, never a reason to show an error over the list.
        if let count = try? await connection.api.unreadNotificationCount() { unreadCount = count }
    }

    /// A quick-filter chip: its statuses, and nothing else narrowed.
    func select(_ filter: SessionFilter) async {
        await apply(filter.filters)
    }

    /// The filter sheet's choices, or a quick filter's; the sheet's board visibility with
    /// them, in one read.
    func apply(_ filters: BoardFilters, board: BoardFilter? = nil) async {
        let board = board ?? self.board
        guard filters != self.filters || board != self.board else { return }
        self.filters = filters
        self.board = board
        sessions = []
        await refresh()
    }

    /// What the list asks for. The Ranked view opens on everything that can still run, as the
    /// web works it out on each request — over the default filters only, and never saved, so
    /// leaving Ranked is back to Needs input.
    var effectiveFilters: BoardFilters {
        view == .ranked && filters == .default ? .ranked : filters
    }

    /// The filters in words, with a genesis by its label once the catalog has been read.
    var filterSummary: String {
        effectiveFilters.summary { key in self.filterOptions?.geneses.first { $0.key == key }?.label }
    }

    func viewChanged() async {
        await refresh()
    }

    func loadFilterOptions() async {
        guard filterOptions == nil else { return }
        do {
            filterOptions = try await connection.api.configs()
        } catch {
            handle(error)
        }
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
            var updated = try await action(connection.api)
            withAnimation {
                if let index = sessions.firstIndex(where: { $0.id == id }) {
                    // An action answers with the session alone: the row's summary stays until
                    // the next read of the list.
                    if updated.boardRow == nil { updated.boardRow = sessions[index].boardRow }
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
        effectiveFilters.admits(session) && board.admits(session)
    }

    /// The rows in the current view's order and sections.
    var sections: [BoardSection] { view.sections(sessions) }

    /// Trash one session as the web UI's Trash does: no question first, *Undo* after. One with
    /// messages queued for it is asked about (`queuedTrash`) unless `force`. A refusal goes to
    /// `onError` when the caller shows its own errors (the session's page), else to the board.
    @discardableResult
    func trash(_ session: SessionSummary, force: Bool = false, onError: ((Error) -> Void)? = nil) async -> Bool {
        do {
            switch try await connection.api.trash(session.id, force: force) {
            case let .trashed(updated):
                withAnimation {
                    if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                        if belongsOnList(updated) { sessions[index] = updated } else { sessions.remove(at: index) }
                    }
                    notice = nil
                    undoable = updated
                }
                error = nil
                Haptics.success()
                return true
            case .queued:
                queuedTrash = session
                return false
            }
        } catch {
            if let onError { onError(error) } else { handle(error); Haptics.failure() }
            return false
        }
    }

    /// The Undo toast's button: restore what was just trashed.
    func undoTrash() async {
        guard let session = undoable else { return }
        withAnimation { undoable = nil }
        if await perform("Restored from trash", on: session.id, { try await $0.unarchive(session.id) }) {
            await refresh()
        }
    }

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

    /// The User view's Merge: the sign-off that lets a session merge its open, green PR.
    func authorizeMerge(_ id: Int) async {
        do {
            notice = try await connection.api.authorizeMerge(id).message
            Haptics.success()
            await refresh()
        } catch {
            handle(error)
            Haptics.failure()
        }
    }

    /// The User view's Reprioritize: the board goes to the reprioritizing session, which
    /// writes the new order back; the list shows it on the next refresh.
    func reprioritize() async {
        do {
            notice = try await connection.api.reprioritize().message
            Haptics.success()
        } catch {
            handle(error)
            Haptics.failure()
        }
    }

    /// An action the server answers with a sentence rather than the session — a row's
    /// *Refresh Transcript* — then the list as it now stands, and the sentence as the toast.
    func run(_ action: (ZimmerAPI) async throws -> String) async {
        do {
            let message = try await action(connection.api)
            await refresh()
            notice = message
            Haptics.success()
        } catch {
            handle(error)
            Haptics.failure()
        }
    }

    /// The Ranked row's *Promote to priority* and *Demote to spot* (which lands at the head of
    /// the spot queue). A promotion starts a waiting session; one that could not says why.
    func reschedule(_ id: Int, priority: Bool) async {
        do {
            let change = try await connection.api.setSchedulingClass(id, priority: priority)
            let done = priority ? "Promoted to priority" : "Demoted to spot, top of the queue"
            notice = change.startMessage.map { "\(done). \($0)" } ?? done
            error = nil
            if change.startOutcome == "refused" { Haptics.failure() } else { Haptics.success() }
            // The list is the server's order: a row that changed class belongs in the other half.
            await refresh()
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

    /// Your board's and Ranked's drag-and-drop, then the list as the server now orders it.
    func reorder(_ id: Int, above: Int?, below: Int?) async {
        do {
            _ = try await connection.api.reorder(id, above: above, below: below)
            // After the reload, so the toast never shows over the row in its old place.
            await refresh()
            notice = view == .ranked ? "Moved in the spot queue" : "Moved on your board"
            Haptics.success()
        } catch {
            handle(error)
            Haptics.failure()
            await refresh()
        }
    }

    /// The web UI's page for a session, for what the app does not do itself.
    func webURL(for id: Int) -> URL? {
        webURL(path: "/sessions/\(id)")
    }

    /// Any page of the web UI, by its path: a trigger's, for editing it, or where a banner sends
    /// a flow only a browser can finish, such as authorizing an MCP server.
    func webURL(path: String) -> URL? {
        guard let web = signedInOrigins?.web else { return nil }
        return ServerURL.join(web, path)
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
        // The next deployment's banners are its own, read on the first refresh.
        systemBanners = SystemBanners()
        bannersCheckedAt = nil
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
