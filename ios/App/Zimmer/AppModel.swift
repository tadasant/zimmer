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
    @Published var showingFilters = false {
        didSet { if showingFilters, fixturePublishesUnderFilters { Task { await publishUnderFilters() } } }
    }
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
    /// The session just trashed, while *Undo* is offered for it. When the offer ends — taken,
    /// expired, or a refusal — the rows kept for it go too, except one whose trash is still out.
    @Published var undoable: SessionSummary? {
        didSet {
            if undoable == nil {
                for id in trashedRows.keys where trashesInFlight[id] == nil { trashedRows[id] = nil }
            }
        }
    }
    /// A trash refused because messages are queued for the session: asked again, naming the
    /// discard, before it goes.
    @Published var queuedTrash: SessionSummary?
    @Published private(set) var sessions: [SessionSummary] = []
    /// The row actions out to the server, laid over every read of the list until each is
    /// answered, so a read from before the action cannot put a trashed row back.
    private var pending = PendingBoardChanges()
    /// The rows a drag just left, in the reorderable views, until the list is read again with
    /// the precedence the server worked out from the drop.
    @Published private(set) var localOrder: [Int]?
    private var reordersInFlight = 0
    /// Each trashed session as it read before the trash, for *Undo* to put back at once.
    private var trashedRows: [Int: SessionSummary] = [:]
    /// The trashes out to the server, by session: an Undo tapped before the answer waits on it.
    private var trashesInFlight: [Int: Task<Bool, Never>] = [:]
    /// Sessions asked for and not yet answered with an id, by the placeholder their page opens
    /// on. Placeholders are negative, so they never name a session.
    @Published private(set) var pendingStarts: [Int: PendingStart] = [:]
    private var startWork: [Int: @MainActor (ZimmerAPI) async throws -> Int] = [:]
    /// The session each placeholder became, for the pages that keep the placeholder as their
    /// path element after adopting the session's id — and for a page remade on the placeholder
    /// after the start was forgotten, which adopts from here.
    private(set) var startedSessions: [Int: Int] = [:]
    private var nextPlaceholder = 0
    @Published private(set) var isLoading = false
    /// The banner over the list: why a read failed, or why the server refused an action.
    @Published var error: ZimmerError? { didSet { errorIsReadFailure = false } }
    /// Whether `error` is a read's failure, which the next read that lands answers. Any other
    /// is the server's refusal of something done here, which the board's background reads
    /// (`pollBoard`, a start finishing in the background) leave up: a poll can land a moment
    /// after the refusal, and would take the reason away before it could be read.
    private var errorIsReadFailure = false
    @Published private(set) var signedInOrigins: ServerOrigins?
    /// When the edge's credential expires, on a deployment that has one.
    @Published private(set) var edgeExpiry: Date?
    /// The navigation stack: session ids, so a push or a deep link can open one.
    @Published var path: [Int] = [] {
        // Opening a session from anywhere (a push, the inbox, a trigger) shows the Sessions tab.
        didSet {
            if !path.isEmpty, tab != .sessions { tab = .sessions }
            // Opening a session is the person's own choice, and a landing would cover it.
            if !path.isEmpty { LiveCall.shared.personChoseElsewhere() }
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
    /// Which reads may replace the list, and when the board reads again.
    private(set) var freshness = BoardFreshness()
    /// Whether the app is in front and whether the poller's read is out.
    private var polling = BoardPolling()
    /// How many times the app has come back to the front: `BoardPoller` restarts on the count.
    @Published private(set) var returnsToFront = 0
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
    /// Live Mode (LiveHomeView), from the session list's waveform button.
    @Published var showingLive = false
    /// The waveform button opened Live: LiveHomeView goes straight into the open conversation with
    /// voice on, or a new one with voice on when none is open, instead of stopping on its list.
    var liveLandsInVoice = false
    /// The waveform button: Live, landing in the open conversation with voice on.
    func openLive() {
        liveLandsInVoice = true
        showingLive = true
    }

    /// A call the car left on the phone: LiveHomeView opens this thread, as it stands. Unlike the
    /// waveform's landing it is not asked to turn voice on, so nothing happens to the call.
    @Published var liveLanding: Int?
    /// The thread Live's sheet is showing; nil on its list.
    var liveThreadOnScreen: Int?
    /// `LiveHandover` said to go: into Live if its sheet is up, or up with it.
    func landOnCall(_ conversation: Int) {
        liveLanding = conversation
        showingLive = true
    }

    /// Live's sheet closed, by Done or a swipe, which is a choice too: the sheet does not pop back
    /// up on a call the person has just walked away from.
    func liveClosed() {
        liveLanding = nil
        liveThreadOnScreen = nil
        LiveCall.shared.personChoseElsewhere()
    }

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
    /// its strip (`hierarchy`, `humanMessages`, `transcript`), as a tap on its chip does.
    var fixtureSection: SessionPageSection?
    /// `-ZimmerFixtureFullScreen`: the opened session's transcript opens full screen.
    var fixtureOpensFullScreen = false
    /// `-ZimmerFixturePublishUnderFilters`: see `publishUnderFilters`.
    var fixturePublishesUnderFilters = false
    /// `-ZimmerFixtureTrigger <id>`, or a link to `/triggers/<id>`: the Triggers tab opens on
    /// that trigger's page.
    @Published var fixtureTrigger: Int?
    /// `-ZimmerFixtureCosts [agent root]`, or a link to `/costs`: More opens on Costs, narrowed
    /// to the root if one is named.
    @Published var fixtureCosts: CostScope?
    /// `-ZimmerFixtureInference [runtime]`: More opens on Inference, on that runtime's tab;
    /// with `-ZimmerFixtureInferenceLogin`, the first account that needs a login starts one,
    /// so `ios/bin/ui-test` can photograph the login sheet.
    @Published var fixtureInference: InferenceOpening?

    struct InferenceOpening: Hashable {
        var runtime: String
        var login: Bool
    }
    /// `-ZimmerFixtureSettings [section]`, or a link to `/settings`: More opens Settings,
    /// scrolled to that section (`defaults`, `experimental`, `mcpApps`) if one is named.
    /// `-ZimmerFixtureAccount`, or a link to `/settings/api_keys`: Settings, with API keys &
    /// connections pushed over it.
    @Published var fixtureSettings: SettingsOpening?
    /// `-ZimmerFixtureHealth`, or a link to `/health`: More opens on Health.
    @Published var fixtureHealth = false
    /// `-ZimmerFixtureTriggerForm`: the opened trigger's edit form starts open — or, with no
    /// trigger opened, the Triggers tab's new-trigger form — so a screenshot can show it.
    var fixtureOpensTriggerForm = false
    /// `-ZimmerFixtureClis`, or a link to `/clis`: More opens on CLIs.
    @Published var fixtureClis = false
    /// Bumped each time a link to one of Zimmer's own pages is opened here, so the full-screen
    /// transcript the link may have been in gets out of the way.
    @Published private(set) var linksOpened = 0
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

    /// Publish from the model again and again under the open Filters sheet, so a UI test can see
    /// the sheet keep its state. A burst, because a sheet presented from a `List` row loses its
    /// state to a publish only now and then. Sixty ticks take well over the nominal nine seconds
    /// on a CI runner, and on a slow one they start before the test has finished scrolling.
    private func publishUnderFilters() async {
        #if DEBUG
        try? await Task.sleep(for: .seconds(10))
        let count = unreadCount
        for tick in 0..<60 {
            unreadCount = tick.isMultiple(of: 2) ? count + 1 : count
            try? await Task.sleep(for: .milliseconds(150))
        }
        #endif
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
        if let flag = arguments.firstIndex(of: "-ZimmerFixtureCarScript"), arguments.indices.contains(flag + 1) {
            runFixtureCarScript(arguments[flag + 1])
        }
        fixtureAttachesFile = arguments.contains("-ZimmerFixtureAttachment")
        fixtureOpensPrompt = arguments.contains("-ZimmerFixtureOpenPrompt")
        fixtureOpensCustomSnooze = arguments.contains("-ZimmerFixtureCustomSnooze")
        fixtureOpensPanels = arguments.contains("-ZimmerFixtureOpenPanels")
        fixtureTypesSlash = arguments.contains("-ZimmerFixtureSlash")
        fixtureOpensFullScreen = arguments.contains("-ZimmerFixtureFullScreen")
        fixturePublishesUnderFilters = arguments.contains("-ZimmerFixturePublishUnderFilters")
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
        if let flag = arguments.firstIndex(of: "-ZimmerFixtureInference") {
            let runtime = arguments.indices.contains(flag + 1) && !arguments[flag + 1].hasPrefix("-") ? arguments[flag + 1] : InferenceReport.claudeCode
            fixtureInference = InferenceOpening(runtime: runtime, login: arguments.contains("-ZimmerFixtureInferenceLogin"))
            tab = .more
        }
        if let flag = arguments.firstIndex(of: "-ZimmerFixtureSettings") {
            let section = arguments.indices.contains(flag + 1) && !arguments[flag + 1].hasPrefix("-") ? arguments[flag + 1] : nil
            fixtureSettings = SettingsOpening(section: section.flatMap(SettingsSection.init(rawValue:)))
            tab = .more
        }
        if arguments.contains("-ZimmerFixtureAccount") {
            fixtureSettings = SettingsOpening(section: nil, account: true)
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
        fixtureOpensTriggerForm = arguments.contains("-ZimmerFixtureTriggerForm")
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

    /// A session left the list's filter (archived) or joined it (started). Read quietly: the
    /// list already shows what changed here, and a spinner over it would say otherwise.
    func sessionChanged() async {
        await refresh(silently: true)
    }

    /// Start a session from the full form, and open its page at once. The form's choices —
    /// root, runtime, catalog — are not the Quick Router's to take back, so a failed start
    /// offers *Try again* alone; a clone starts from no words at all.
    func createSession(_ request: NewSessionRequest) {
        startSession(prompt: request.cloneOnly ? nil : request.prompt, title: request.title ?? request.agentRoot, editable: false) {
            try await $0.createSession(request).id
        }
    }

    /// Start a session and, with `open`, show its page before the server has answered with its
    /// id: the page opens on a placeholder, with the words (`prompt`, when the start has any)
    /// on their way, and fills in as the session once it exists. A start that fails shows on
    /// that page with *Try again* and — for a Quick Router start, `editable` — *Edit*, the
    /// words back in the Quick Router; one asked for in the background puts them back there
    /// at once. Returns the placeholder, which `pendingStarts` is keyed by.
    @discardableResult
    func startSession(prompt: String?, title: String, open: Bool = true, editable: Bool = true,
                      start: @escaping @MainActor (ZimmerAPI) async throws -> Int) -> Int {
        nextPlaceholder -= 1
        let placeholder = nextPlaceholder
        pendingStarts[placeholder] = PendingStart(prompt: prompt, title: title, opens: open, editable: editable)
        startWork[placeholder] = start
        if open { path.append(placeholder) }
        Haptics.success()
        Task { await runStart(placeholder) }
        return placeholder
    }

    /// The pending page's *Try again*: the same start, asked once more.
    func retryStart(_ placeholder: Int) {
        guard pendingStarts[placeholder]?.state.isFailed == true else { return }
        pendingStarts[placeholder]?.state = .starting
        Task { await runStart(placeholder) }
    }

    /// The pending page's *Edit*: the words back in the Quick Router, the start forgotten.
    /// The sheet is presented once the page has popped, as a sheet asked for during a pop can
    /// be refused and leave its flag set with nothing shown.
    func editStart(_ placeholder: Int) {
        guard let start = pendingStarts[placeholder], start.editable else { return }
        forgetStart(placeholder)
        if path.last == placeholder { path.removeLast() }
        presentAfterCover { $0.openQuickRouter(draft: start.prompt ?? "") }
    }

    /// A start's page left, or its session opened: the placeholder has nothing more to say.
    func forgetStart(_ placeholder: Int) {
        pendingStarts[placeholder] = nil
        startWork[placeholder] = nil
    }

    private func runStart(_ placeholder: Int) async {
        guard let work = startWork[placeholder] else { return }
        do {
            let id = try await work(connection.api)
            startWork[placeholder] = nil
            startedSessions[placeholder] = id
            pendingStarts[placeholder]?.state = .started(id)
            // Asked for in the background, or its page left before the answer: no page will
            // take the id, so the toast says where the session is.
            if pendingStarts[placeholder]?.opens == false || !path.contains(placeholder) {
                notice = "Started session #\(id)"
                forgetStart(placeholder)
            }
            await refresh(silently: true, onItsOwn: true)
        } catch {
            let zimmerError = error as? ZimmerError ?? .transport(error)
            log.error("start failed: \(String(describing: zimmerError), privacy: .public)")
            Haptics.failure()
            if zimmerError == .unauthorized { handle(error) }
            guard let start = pendingStarts[placeholder] else { return }
            if start.opens, path.contains(placeholder) {
                pendingStarts[placeholder]?.state = .failed(zimmerError)
            } else {
                // Asked for in the background, or its page already left: there is no page to
                // say so. The refusal shows over the screen in front, and Quick Router words go
                // back to the Quick Router.
                forgetStart(placeholder)
                handle(error)
                if start.editable, let prompt = start.prompt { openQuickRouter(draft: prompt) }
            }
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

    /// Start a Quick Router session and open it, at once.
    func startQuickRouter(_ prompt: String) {
        startQuickRouter(QuickRouterRequest(prompt: prompt))
    }

    /// Start a Quick Router session with the sheet's choices and open its page at once — or,
    /// with `open` off, the web bubble's plain *Submit*: the session starts and this screen
    /// stays, with a toast once it has. Either way the sheet closes on the tap, not the answer.
    func startQuickRouter(_ request: QuickRouterRequest, open: Bool = true) {
        showingQuickRouter = false
        quickRouterParent = nil
        quickRouterPage = nil
        if !open { notice = "Starting a session in the background…" }
        startSession(prompt: request.prompt, title: "Quick Router", open: open, editable: true) { try await $0.startQuickRouter(request) }
    }

    /// `silently`: no loading state, and a failure other than a sign-in that ended is not
    /// shown; the next read tries again. `onItsOwn`: the poller's read, or the one after a
    /// start finished in the background — it clears a read's failure from the banner but not
    /// an action's refusal. Every other read clears both.
    func refresh(silently: Bool = false, onItsOwn: Bool = false) async {
        if !silently { isLoading = true }
        defer { if !silently { isLoading = false } }
        let ticket = freshness.begin()
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
            // A slower answer to an older request must not overwrite a newer list, nor put
            // back a row trashed here since it was asked.
            guard requested == effectiveFilters, board == self.board, view == self.view,
                  query == searchText.trimmingCharacters(in: .whitespacesAndNewlines),
                  freshness.finish(ticket) else { return }
            // The actions still out keep what they changed; the server's list is the rest.
            sessions = pending.overlay(result.sessions, admits: belongsOnList)
            if reordersInFlight == 0 { localOrder = nil }
            listIncomplete = !result.complete
            if !onItsOwn || errorIsReadFailure { error = nil }
        } catch {
            // A read cancelled with the screen that asked (the board pushed under a session,
            // another tab chosen) did not fail, and an older read's failure is not worth a
            // banner over what a newer one brings.
            if !Task.isCancelled {
                freshness.fail(ticket)
                if freshness.isNewest(ticket), !silently || (error as? ZimmerError) == .unauthorized { handleReadFailure(error) }
            }
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

    /// The board is the screen in front: not under an open session or another tab, and not
    /// while a selection or a drag is in hand.
    private var boardIsInFront: Bool { tab == .sessions && path.isEmpty && !isEditingBoard }

    /// The board's read of its own (`BoardPoller`): silent, one at a time, only while the app is
    /// in front, and only of the board in front. With `ifStale`, only when the list was not read
    /// moments ago.
    func pollBoard(ifStale: Bool = false) async {
        guard boardIsInFront, !ifStale || freshness.isStale(), polling.beginPoll() else { return }
        defer { polling.endPoll() }
        await refresh(silently: true, onItsOwn: true)
    }

    /// The scene's phase changed (`RootView`, the scene's root, so it is heard whatever screen
    /// is showing). Synchronous, so the poller is held before the app can be suspended, and
    /// `BoardPoller` restarts (`returnsToFront`) as the app comes back.
    func sceneChanged(to phase: ScenePhase) {
        switch phase {
        case .background:
            polling.wentToBackground()
        case .active:
            polling.cameToFront()
            returnsToFront = polling.returns
        default:
            break
        }
    }

    /// The reads a change of phase calls for, after `sceneChanged(to:)`.
    ///
    /// Back in front, signed out: read the Keychain again — a sign-in that a launch in the
    /// background could not read comes back here; a real sign-out reads back nothing. Back in
    /// front, signed in: read the board at once (`readBoardOnReturn`). A cold launch reads the
    /// board in `start()`; a `.active` heard during the launch is at most a second read, which
    /// the tickets resolve.
    func sceneEntered(_ phase: ScenePhase) async {
        switch phase {
        case .background:
            await trashFixtureSessionWhileAway()
        case .active:
            switch isSignedIn {
            case .some(false): await start()
            case .some(true): await readBoardOnReturn()
            case .none: break
            }
        default:
            break
        }
    }

    #if DEBUG
    /// `-ZimmerFixtureCarScript left@6,back@7,end@9`: a call from the car on conversation 21, held
    /// on Connecting…, and the car's moves at those seconds after launch, so a phone test can see
    /// what a disconnect does in every order. `left` and `back` are what the CarPlay scene calls.
    private func runFixtureCarScript(_ script: String) {
        let moves = script.split(separator: ",").compactMap { move -> (name: Substring, at: Double)? in
            let parts = move.split(separator: "@")
            guard parts.count == 2, let at = Double(parts[1]) else { return nil }
            return (parts[0], at)
        }
        // A real call's audio keeps the app running in a pocket. This held one has no audio yet, so
        // the script asks for the time itself, or iOS would suspend it behind a test's Home press.
        let running = UIApplication.shared.beginBackgroundTask(withName: "fixture-car-script")
        Task {
            defer { UIApplication.shared.endBackgroundTask(running) }
            let call = LiveCall.shared
            // `other@0`: the call is on a new conversation, for a thread that is not the call's.
            let other = moves.contains { $0.name == "other" }
            let conversation = other ? (try? await connection.api.startLiveConversation(.voice).id) ?? 21 : 21
            Task { await call.start(conversation, from: .carplay) }
            var elapsed = 0.0
            for move in moves {
                try? await Task.sleep(for: .seconds(move.at - elapsed))
                elapsed = move.at
                switch move.name {
                case "left": call.carLeft()
                case "back":
                    call.carCameBack()
                    await call.carryOn(on: .carplay)
                case "end": call.hangUp()
                default: break
                }
            }
        }
    }
    #endif

    /// `-ZimmerFixtureTrashedWhileAway <id>`: session `id` goes to the trash elsewhere as the
    /// app goes to the background, so a UI test can see the board catch up on its return.
    private func trashFixtureSessionWhileAway() async {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard environment.isFixture, let fake = connection.api as? FakeZimmerAPI,
              let flag = arguments.firstIndex(of: "-ZimmerFixtureTrashedWhileAway"),
              arguments.indices.contains(flag + 1), let id = Int(arguments[flag + 1]) else { return }
        await fake.trashElsewhere(id)
        #endif
    }

    /// The read on coming back to the front. It does not wait on the poller's read, which the
    /// phone may have suspended mid-flight (`BoardPolling`); a newer ticket wins. A phone just
    /// back from the background often has no network for its first request, so a failed read is
    /// tried once more shortly after.
    private func readBoardOnReturn() async {
        guard boardIsInFront else { return }
        await refresh(silently: true)
        guard freshness.lastReadFailed else { return }
        try? await Task.sleep(for: BoardFreshness.foregroundRetry)
        guard boardIsInFront, polling.inFront else { return }
        await refresh(silently: true)
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
            handleReadFailure(error)
        }
    }

    func select(_ board: BoardFilter) async {
        guard board != self.board else { return }
        self.board = board
        sessions = []
        await refresh()
    }

    /// One action on one session from the list (a swipe or a long press). With `optimistic`,
    /// the row changes at the tap — `optimistic` writes what the server is expected to answer
    /// onto a copy of it — and the server is asked after; its answer replaces the row, and a
    /// refusal puts the row back as it was, with the refusal over the list. Without
    /// `optimistic`, the toast still shows at the tap and the row changes on the answer. A row
    /// that no longer belongs on this list leaves it; one that now does joins it. `seed` is the
    /// row to start from when the list does not have it (one just trashed, being restored).
    @discardableResult
    func perform(_ done: String, on id: Int, optimistic: ((inout SessionSummary) -> Void)? = nil, seed: SessionSummary? = nil,
                 _ action: (ZimmerAPI) async throws -> SessionSummary) async -> Bool {
        await performRow(done, on: id, optimistic: optimistic, seed: seed, action) { $0 } != nil
    }

    /// `perform`, for an action the server answers with more than the session (`row` picks it
    /// out). Nil when it failed.
    private func performRow<Answer>(_ done: String, on id: Int, optimistic: ((inout SessionSummary) -> Void)?, seed: SessionSummary?,
                                    _ action: (ZimmerAPI) async throws -> Answer, row: (Answer) -> SessionSummary) async -> Answer? {
        let before = sessions.first { $0.id == id }
        var ticket: PendingBoardChanges.Ticket?
        if let optimistic, var guess = before ?? seed {
            optimistic(&guess)
            ticket = pending.begin(id, belongsOnList(guess) ? .replaced(guess) : .removed)
            freshness.noteLocalChange()
            withAnimation { sessions = pending.overlay(sessions, admits: belongsOnList) }
        }
        // At the tap, as the web UI's toast is: the server is expected to agree.
        notice = done
        error = nil
        Haptics.success()
        do {
            let answer = try await action(connection.api)
            // Ended only when it still stood in for the row: a newer action on the same row,
            // asked meanwhile, is what the list shows until its own answer.
            let stands = ticket.map { pending.end($0) } ?? true
            freshness.noteLocalChange()
            if stands { withAnimation { place(row(answer), keeping: before?.boardRow) } }
            return answer
        } catch {
            let stands = ticket.map { pending.end($0) } ?? false
            freshness.noteLocalChange()
            if stands {
                withAnimation {
                    // A row that was on the list goes back as it was; one the action brought
                    // onto the list (a restore from the trash) leaves it again.
                    if let before { restore(before) } else { sessions.removeAll { $0.id == id } }
                }
            }
            refused(error, undoing: done)
            return nil
        }
    }

    /// The server's row takes its place: over the row it had, on the list when it has none and
    /// belongs, off it when it no longer does. An action answers with the session alone, so
    /// the row's board summary stays until the next read of the list.
    private func place(_ updated: SessionSummary, keeping boardRow: BoardRow?) {
        var updated = updated
        if let index = sessions.firstIndex(where: { $0.id == updated.id }) {
            if updated.boardRow == nil { updated.boardRow = sessions[index].boardRow ?? boardRow }
            if belongsOnList(updated) { sessions[index] = updated } else { sessions.remove(at: index) }
        } else if belongsOnList(updated) {
            if updated.boardRow == nil { updated.boardRow = boardRow }
            sessions.append(updated)
        }
    }

    /// A row as it read before an action the server refused, back on the list. Where in the
    /// array does not matter: `sections` orders every view.
    private func restore(_ row: SessionSummary) {
        if let index = sessions.firstIndex(where: { $0.id == row.id }) {
            sessions[index] = row
        } else if belongsOnList(row) {
            sessions.append(row)
        }
    }

    private func belongsOnList(_ session: SessionSummary) -> Bool {
        effectiveFilters.admits(session) && board.admits(session)
    }

    /// The rows in the current view's order and sections — a drag's order first, until the
    /// server's read replaces it.
    var sections: [BoardSection] { view.sections(sessions, order: localOrder) }

    /// Trash one session as the web UI's Trash does: no question first, *Undo* after. The row
    /// goes at the tap, with Undo offered, and the server is asked after; a refusal puts the
    /// row back, drops the Undo, and shows over the board. One with messages queued for it is
    /// asked about (`queuedTrash`) unless `force` — its row comes back for the question.
    @discardableResult
    func trash(_ session: SessionSummary, force: Bool = false) async -> Bool {
        let id = session.id
        // Held while out, so an Undo tapped before the answer waits for it rather than
        // asking the server to restore a session it has not archived yet.
        let task = Task { await performTrash(session, force: force) }
        trashesInFlight[id] = task
        let trashed = await task.value
        if trashesInFlight[id] == task { trashesInFlight[id] = nil }
        return trashed
    }

    private func performTrash(_ session: SessionSummary, force: Bool) async -> Bool {
        let id = session.id
        let before = sessions.first { $0.id == id } ?? session
        var guess = before
        guess.expectTrashed()
        let ticket = pending.begin(id, belongsOnList(guess) ? .replaced(guess) : .removed)
        freshness.noteLocalChange()
        trashedRows[id] = before
        withAnimation {
            sessions = pending.overlay(sessions, admits: belongsOnList)
            notice = nil
            undoable = guess
        }
        error = nil
        Haptics.success()
        do {
            switch try await connection.api.trash(id, force: force) {
            case let .trashed(updated):
                let stands = pending.end(ticket)
                freshness.noteLocalChange()
                if stands {
                    withAnimation { place(updated, keeping: before.boardRow) }
                    if undoable?.id == id { undoable = updated }
                }
                return true
            case .queued:
                putBack(ticket, before)
                queuedTrash = session
                return false
            }
        } catch {
            putBack(ticket, before)
            refused(error, undoing: "Moved to trash")
            return false
        }
    }

    /// An action shown at the tap that the server refused: the banner over the list says
    /// why, and a toast says it at the foot of the screen, where the eye is — the banner is
    /// the list's first row, which a list scrolled down keeps out of sight.
    private func refused(_ error: Error, undoing done: String) {
        handle(error)
        let zimmerError = error as? ZimmerError ?? .transport(error)
        notice = "Not \(done.prefix(1).lowercased() + done.dropFirst()): \(zimmerError.userMessage)"
        Haptics.failure()
    }

    /// A trash the server did not take: the row as it was, no Undo for it.
    private func putBack(_ ticket: PendingBoardChanges.Ticket, _ before: SessionSummary) {
        let stands = pending.end(ticket)
        freshness.noteLocalChange()
        trashedRows[ticket.id] = nil
        withAnimation {
            if stands { restore(before) }
            if undoable?.id == ticket.id { undoable = nil }
        }
    }

    /// The Undo toast's button: what was just trashed, back on the list as it read before the
    /// trash, at once; the server's row replaces it when the restore is answered.
    func undoTrash() async {
        guard let session = undoable else { return }
        let id = session.id
        let original = trashedRows[id] ?? session
        withAnimation { undoable = nil }
        // A trash still out is answered first: the server refuses to restore a session it has
        // not yet archived. One it refused has put the row back already — nothing to undo.
        if let inFlight = trashesInFlight[id], await inFlight.value == false { return }
        trashedRows[id] = nil
        await perform("Restored from trash", on: id, optimistic: { $0 = original }, seed: original) { try await $0.unarchive(id) }
    }

    /// Trash the selected sessions: gone at the tap, asked after. Each refusal comes back with
    /// the server's reason; the rest go.
    func trash(_ ids: Set<Int>) async {
        let ordered = Array(ids).sorted()
        var tickets: [Int: PendingBoardChanges.Ticket] = [:]
        var befores: [Int: SessionSummary] = [:]
        for row in sessions where ids.contains(row.id) {
            befores[row.id] = row
            var guess = row
            guess.expectTrashed()
            tickets[row.id] = pending.begin(row.id, belongsOnList(guess) ? .replaced(guess) : .removed)
        }
        freshness.noteLocalChange()
        withAnimation { sessions = pending.overlay(sessions, admits: belongsOnList) }
        notice = "Moved \(ids.count) to trash"
        error = nil
        Haptics.success()
        do {
            let result = try await connection.api.bulkArchive(ordered)
            for ticket in tickets.values { pending.end(ticket) }
            freshness.noteLocalChange()
            let refused = result.errors.map { "#\($0.id): \($0.message)" }
            withAnimation {
                for refusal in result.errors { if let before = befores[refusal.id] { restore(before) } }
            }
            await refresh(silently: true)
            // After the refresh, which clears the banner: the refusals are what it is for.
            notice = "Moved \(result.archivedCount) to trash" + (refused.isEmpty ? "" : "; \(refused.count) refused")
            if !refused.isEmpty {
                error = .http(status: 422, message: refused.joined(separator: "\n"))
                Haptics.failure()
            }
        } catch {
            for ticket in tickets.values { pending.end(ticket) }
            freshness.noteLocalChange()
            withAnimation { for before in befores.values { restore(before) } }
            refused(error, undoing: "Moved to trash")
        }
    }

    func refreshAll() async {
        do {
            let summary = try await connection.api.refreshAll()
            notice = summary
            Haptics.success()
            await refresh(silently: true)
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
            await refresh(silently: true)
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
    /// *Refresh Transcript* — the sentence as the toast, then the list as it now stands.
    func run(_ action: (ZimmerAPI) async throws -> String) async {
        do {
            let message = try await action(connection.api)
            notice = message
            Haptics.success()
            await refresh(silently: true)
        } catch {
            handle(error)
            Haptics.failure()
        }
    }

    /// The Ranked row's *Promote to priority* and *Demote to spot* (which lands at the head of
    /// the spot queue). The row crosses to the other half at the tap; a promotion starts a
    /// waiting session, and one that could not says why once the server has answered.
    func reschedule(_ id: Int, priority: Bool) async {
        let done = priority ? "Promoted to priority" : "Demoted to spot, top of the queue"
        let change = await performRow(done, on: id, optimistic: { $0.expectPriority(priority) }, seed: nil,
                                      { try await $0.setSchedulingClass(id, priority: priority) }, row: \.session)
        guard let change else { return }
        notice = change.startMessage.map { "\(done). \($0)" } ?? done
        if change.startOutcome == "refused" { Haptics.failure() }
        // The list is the server's order: where in the other half the row lands is its say.
        await refresh(silently: true)
    }

    /// The Ranked view's *Start now*.
    func startNow(_ id: Int) async {
        do {
            notice = try await connection.api.startNow(id)
            Haptics.success()
            await refresh(silently: true)
        } catch {
            handle(error)
            Haptics.failure()
        }
    }

    /// Your board's and Ranked's drag-and-drop: the rows stay where the drag left them
    /// (`moved`, which `sections` shows) while the server is told what the dropped row landed
    /// between and works out its precedence; the list is then read as the server orders it. A
    /// refused drop snaps the rows back, with the refusal over the list.
    func reorder(_ moved: [SessionSummary], id: Int, above: Int?, below: Int?) async {
        localOrder = moved.map(\.id)
        reordersInFlight += 1
        freshness.noteLocalChange()
        notice = view == .ranked ? "Moved in the spot queue" : "Moved on your board"
        error = nil
        Haptics.success()
        do {
            _ = try await connection.api.reorder(id, above: above, below: below)
            // Only the read after the last drop in flight may put the server's order up.
            reordersInFlight -= 1
            freshness.noteLocalChange()
            await refresh(silently: true)
        } catch {
            reordersInFlight -= 1
            if reordersInFlight == 0 { localOrder = nil }
            notice = nil
            await refresh(silently: true)
            // After the read, which clears the banner: the refusal is what it is for.
            handle(error)
            Haptics.failure()
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

    /// A link to one of this Zimmer's own pages, opened on the app's screen for it rather than
    /// in a browser. False when it is not one — another host, or a page the app has no screen
    /// for — and the caller opens it as any link.
    func openInApp(_ url: URL) -> Bool {
        guard let origins = signedInOrigins, let link = ZimmerLink(url: url, origins: origins) else { return false }
        if case let .session(id) = link, isInFront(id) {
            // A link to a message of the session already open: the web page scrolls to it, and
            // this one cannot yet, so it opens there. Without one there is nothing to do.
            return url.fragment?.isEmpty ?? true
        }
        log.info("opening \(url.path, privacy: .public) in the app")
        open(link)
        return true
    }

    /// Whether the page in front is session `id`'s — pushed as its id, or as the placeholder of
    /// the start that became it.
    func isInFront(_ id: Int) -> Bool {
        guard let last = path.last else { return false }
        return last == id || startedSessions[last] == id
    }

    /// What `MarkdownText` opens links with, made once: a fresh closure on every render of the
    /// tabs would replace `openURL` under every message on every board poll.
    lazy var inAppLinks = InAppLinks(open: { [weak self] url in self?.openInApp(url) ?? false })

    /// The app's screen for a page of the web UI, wherever the link to it was tapped.
    func open(_ link: ZimmerLink) {
        linksOpened += 1
        LiveCall.shared.personChoseElsewhere()
        showingQuickRouter = false
        showingLive = false
        showingNewSession = false
        switch link {
        case .board:
            tab = .sessions
            path = []
        case let .session(id):
            // Pushed over the page the link was on, so Back returns to it.
            path.append(id)
        case let .sessionSlug(slug):
            // The screen is keyed by id, and the server knows which session the slug names. A
            // slug it cannot resolve opens in the browser, whose page says why.
            Task {
                if let id = try? await connection.api.session(slug: slug).session.id {
                    if path.last != id { path.append(id) }
                } else if let url = webURL(path: "/sessions/\(slug)") {
                    _ = await UIApplication.shared.open(url)
                }
            }
        case .newSession:
            presentAfterCover { $0.showingNewSession = true }
        case .inbox:
            tab = .inbox
        case .triggers:
            tab = .triggers
        case let .trigger(id):
            fixtureTrigger = id
            tab = .triggers
        case let .costs(scope):
            fixtureCosts = scope
            tab = .more
        case .health:
            fixtureHealth = true
            tab = .more
        case .clis:
            fixtureClis = true
            tab = .more
        case .settings:
            tab = .more
            presentAfterCover { $0.fixtureSettings = SettingsOpening() }
        case .apiKeys:
            tab = .more
            presentAfterCover { $0.fixtureSettings = SettingsOpening(account: true) }
        case .live:
            presentAfterCover { $0.showingLive = true }
        }
    }

    /// A sheet asked for by a link tapped in the full-screen transcript, which `linksOpened` is
    /// closing: presented once the cover is gone, since UIKit refuses a second presentation
    /// while one is still on screen and would leave the sheet's flag set with nothing shown.
    private func presentAfterCover(_ present: @escaping @MainActor @Sendable (AppModel) -> Void) {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            if let self { present(self) }
        }
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
        freshness.noteLocalChange()
        forgetEverythingInFlight()
        sessions = []
        signedInOrigins = nil
        edgeExpiry = nil
        // The next deployment's banners are its own, read on the first refresh.
        systemBanners = SystemBanners()
        bannersCheckedAt = nil
        isSignedIn = false
    }

    /// The sign-in ended: nothing shown ahead of an answer is this account's any more.
    private func forgetEverythingInFlight() {
        pending = PendingBoardChanges()
        localOrder = nil
        undoable = nil
        trashedRows = [:]
        trashesInFlight = [:]
        pendingStarts = [:]
        startWork = [:]
        startedSessions = [:]
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
            freshness.noteLocalChange()
            forgetEverythingInFlight()
            sessions = []
        }
        self.error = zimmerError
    }

    /// A read that failed: shown as `handle` shows it, and answered by the next read that lands.
    private func handleReadFailure(_ error: Error) {
        handle(error)
        errorIsReadFailure = true
    }
}

/// A session asked for and not yet answered with its id: what its page shows meanwhile.
struct PendingStart: Equatable {
    enum State: Equatable {
        /// Asked of the server; no answer yet.
        case starting
        /// The server answered with the session's id: the page is that session's from here on.
        case started(Int)
        /// The server refused the start, or was never reached. The words are kept.
        case failed(ZimmerError)

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    /// The words the session starts from — the first message its page shows, on its way. Nil
    /// for a start without any: a fork, a clone.
    var prompt: String?
    /// What the page is titled until the session has one: "Quick Router", the agent root.
    var title: String
    /// Whether a page opened on it. Without one, the start's outcome is a toast or a refusal
    /// over the screen it was asked from.
    var opens: Bool
    /// Whether the words can go back to the Quick Router for another go: true for a Quick
    /// Router start, false for the form's (its choices are not the router's) and a fork's.
    var editable: Bool
    var state: State = .starting
}
