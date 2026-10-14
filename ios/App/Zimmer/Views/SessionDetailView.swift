import SwiftUI
import ZimmerKit

/// One session's state, for the detail screen. Holds no rules of its own: what can be
/// followed up or archived is `SessionDetail`'s, what happens is the server's.
@MainActor
final class SessionDetailModel: ObservableObject {
    let id: Int
    let api: ZimmerAPI
    /// Hands an error the whole app cares about (a sign-in that ended) to `AppModel`.
    var report: (ZimmerError) -> Void = { _ in }

    @Published private(set) var detail: SessionDetail? { didSet { noteChange() } }
    /// The newest window and the pages read back past the server's one-read cap.
    @Published private(set) var pages = ConversationPages() { didSet { noteChange() } }
    /// The newest window, as last read.
    var conversation: Conversation? { pages.newest }
    /// How far back the conversation reads: a hundred at first, a hundred more on *Show
    /// earlier*, up to what the server returns in one read.
    @Published private(set) var conversationLimit = Conversation.pageSize
    /// *Show earlier* is reading: a second tap waits for it, and polls stand aside.
    @Published private(set) var isLoadingEarlier = false
    /// The session has been opened once, as a person opening it (`viewed=true`); later
    /// reads are the page keeping current and record nothing.
    private var opened = false
    /// Called once the open has marked the session's notifications read, for the badge.
    var onOpened: () -> Void = {}
    @Published private(set) var isLoading = false
    @Published private(set) var isSending = false
    @Published var error: ZimmerError?
    @Published var notice: String?
    /// What is typed and not yet sent, kept per session across leaving and relaunching.
    @Published var draft: String {
        didSet { drafts.save(draft, for: id) }
    }
    private let drafts = DraftStore()
    /// The messages waiting for the turn in flight to end (`QueueCard`).
    @Published var queue: [QueuedMessage] = [] { didSet { noteChange() } }
    /// Messages accepted and never delivered (`UndeliveredCard`): read-only, as the web shows them.
    @Published private(set) var undelivered: [QueuedMessage] = [] { didSet { noteChange() } }
    /// Bumped by every change to what is shown that does not come from a poll, so a poll that
    /// read before an edit landed throws its stale answer away rather than undoing the edit.
    private var revision = 0
    private var applyingPoll = false
    /// The queue's manager is open: a poll then would move rows under a finger.
    var pollPaused = false
    /// Photos and files going with the next message.
    @Published var attachments: [MessageAttachment] = []
    /// The catalog (`GET /api/v1/configs`), read once: what names the session's goal and
    /// what the goal picker offers. Nil until it reads, and the page works without it.
    @Published private(set) var configs: AppConfigs?
    /// The skills catalog (`GET /api/v1/skills`), read once: what the composer's "/" offers,
    /// narrowed to this session's own. Nil until it reads, and the composer works without it.
    @Published private(set) var skills: [CatalogItem]?
    private var loadingConfigs = false

    init(id: Int, api: ZimmerAPI) {
        self.id = id
        self.api = api
        self.draft = DraftStore().draft(for: id)
    }

    func load() async {
        // Beside the page's own reads, not before them: the catalog only names the goal and
        // fills the composer's "/".
        if configs == nil || skills == nil, !loadingConfigs {
            loadingConfigs = true
            Task { await loadConfigs() }
        }
        isLoading = true
        defer { isLoading = false }
        do {
            if opened {
                detail = try await api.session(id)
            } else {
                detail = try await api.openSession(id)
                opened = true
                onOpened()
            }
            pages.receive(try await api.conversation(id, limit: conversationLimit))
            // The queue is a panel, not the page: one that will not load keeps what it last
            // showed rather than failing the session — unless the sign-in has ended.
            do {
                queue = try await api.queue(id)
                undelivered = try await api.undeliveredMessages(id)
            } catch ZimmerError.unauthorized {
                report(.unauthorized)
            } catch {}
            error = nil
        } catch {
            fail(error)
        }
    }

    /// The catalog and the skills, once each. One that will not read leaves the goal's words,
    /// or "/" offering nothing, and the next load tries again.
    private func loadConfigs() async {
        defer { loadingConfigs = false }
        if configs == nil {
            do {
                configs = try await api.configs()
            } catch ZimmerError.unauthorized {
                report(.unauthorized)
            } catch {}
        }
        if skills == nil {
            do {
                skills = try await api.catalog(.skills)
            } catch ZimmerError.unauthorized {
                report(.unauthorized)
            } catch {}
        }
    }

    /// Read everything again without showing it: the web UI's page updates as the session
    /// moves, and this is that, by asking. A failed read leaves what is on screen, except a
    /// sign-in that ended.
    func poll() async {
        guard !isLoading, !isSending, !isLoadingEarlier, !pollPaused, detail?.session.status != .archived else { return }
        let started = revision
        let limit = conversationLimit
        do {
            let latest = try await api.session(id)
            // The last few messages, joined to what is on screen; the whole window again only
            // when they cannot be, so a running session is not read in full every few seconds.
            var read = pages
            if !read.receiveTail(try await api.conversation(id, limit: ConversationPages.tailSize)) {
                read.receive(try await api.conversation(id, limit: limit))
            }
            let wantsQueue = latest.session.status == .running || latest.session.status == .waiting || !queue.isEmpty
            let queued = wantsQueue ? try? await api.queue(id) : []
            // A message that left the queue was delivered or retired as stale; only then is
            // there anything new to read about what was never delivered.
            let retired: [QueuedMessage]? = queued != nil && queued != queue ? try? await api.undeliveredMessages(id) : nil
            // An edit, a send or *Show earlier* landed while this was reading: its answer wins.
            guard started == revision, limit == conversationLimit, !pollPaused else { return }
            applyingPoll = true
            defer { applyingPoll = false }
            if latest != detail { detail = latest }
            if read != pages { pages = read }
            if let queued, queued != queue { queue = queued }
            if let retired, retired != undelivered { undelivered = retired }
            // The error on screen is an action's (a poll's own failures are never shown), so
            // a quiet read leaves it for the person to read.
        } catch ZimmerError.unauthorized {
            report(.unauthorized)
        } catch {}
    }

    private func noteChange() {
        if !applyingPoll { revision += 1 }
    }

    /// How often to read again: often while a turn is running or about to, rarely otherwise.
    var pollInterval: Duration {
        switch detail?.session.status {
        case .running, .waiting: return .seconds(5)
        default: return .seconds(20)
        }
    }

    /// Widen the window by a page and read again: the web UI's transcript reading back as
    /// you scroll up.
    func showEarlier() async {
        guard !isLoadingEarlier else { return }
        isLoadingEarlier = true
        defer { isLoadingEarlier = false }
        if conversationLimit < Conversation.maxLimit {
            let next = min(conversationLimit + Conversation.pageSize, Conversation.maxLimit)
            do {
                pages.receive(try await api.conversation(id, limit: next))
                // Only once the wider read is on screen: a read that failed leaves the button.
                conversationLimit = next
                error = nil
            } catch {
                fail(error)
            }
            return
        }
        // Past the cap, a page at a time from the oldest message on screen, as the web UI's
        // transcript reads back as you scroll up.
        guard let shown = shownConversation, shown.firstPosition > 0 else { return }
        do {
            let page = try await api.earlierMessages(id, before: shown.firstPosition, limit: Conversation.pageSize)
            pages.prepend(page, before: shown.firstPosition)
            error = nil
        } catch {
            fail(error)
        }
    }

    /// What the page shows: the pages read back, then the newest window.
    var shownConversation: Conversation? { pages.shown }

    func fail(_ error: Error) {
        let zimmerError = error as? ZimmerError ?? .transport(error)
        self.error = zimmerError
        report(zimmerError)
        Haptics.failure()
    }

    /// Send the draft: delivered now, or queued behind a turn in flight. `now` ends that
    /// turn instead — the web UI's "Send Now".
    func send(now: Bool = false) async {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        isSending = true
        defer { isSending = false }
        do {
            let result: FollowUpResult
            let sending = attachments
            if !sending.isEmpty {
                result = try await api.followUp(id, prompt: prompt, attachments: sending, now: now)
            } else if now {
                result = try await api.sendNow(id, prompt: prompt)
            } else {
                result = try await api.followUp(id, prompt: prompt)
            }
            draft = ""
            // Only what went: anything added while it was sending stays for the next message.
            attachments.removeAll { attached in sending.contains { $0.id == attached.id } }
            notice = result.queued ? "Queued — it goes in when the current turn ends." : (now ? "Sent now." : "Sent.")
            error = nil
            Haptics.success()
            await load()
        } catch {
            fail(error)
        }
    }

    /// Add what the pickers returned, refusing anything the server would refuse — the whole
    /// message would fail on it — and saying what could not be read at all.
    func attach(_ new: [MessageAttachment], problems: [String] = []) {
        var refusals = problems
        for attachment in new {
            if let refusal = MessageAttachment.refusal(adding: attachment, to: attachments) {
                refusals.append(refusal)
            } else {
                attachments.append(attachment)
            }
        }
        if let first = refusals.first {
            notice = refusals.count == 1 ? first : "\(first) (and \(refusals.count - 1) more not attached)"
            Haptics.failure()
        }
    }

    /// One action from the session's menu; the server's answer replaces what is shown.
    @discardableResult
    func apply(_ done: String, _ action: (ZimmerAPI) async throws -> SessionSummary) async -> Bool {
        do {
            let session = try await action(api)
            detail?.session = session
            notice = done
            error = nil
            Haptics.success()
            return true
        } catch {
            fail(error)
            return false
        }
    }

    /// Promote or demote. A promotion that tried to start the session and could not says why,
    /// rather than claiming it worked.
    func reschedule(priority: Bool) async {
        do {
            let change = try await api.setSchedulingClass(id, priority: priority)
            detail?.session = change.session
            let done = priority ? "Promoted to priority." : "Demoted to spot, top of the queue."
            notice = change.startMessage.map { "\(done) \($0)" } ?? done
            error = nil
            if change.startOutcome == "refused" { Haptics.failure() } else { Haptics.success() }
            // Why it was waiting has changed with it: the banners are read again.
            await load()
        } catch {
            fail(error)
        }
    }

    /// The web page's class select, in its words: *Derive it* lets the genesis decide again.
    /// Like a promotion, a change that makes a waiting session priority starts it, and one
    /// that could not says why.
    func setSchedulingClass(_ choice: SchedulingClassChoice) async {
        do {
            let change = try await api.setSchedulingClass(id, to: choice)
            detail?.session = change.session
            let done = "This session is now \(change.session.priorityClass ?? "derived")."
            notice = change.startMessage.map { "\(done) \($0)" } ?? done
            error = nil
            if change.startOutcome == "refused" { Haptics.failure() } else { Haptics.success() }
            await load()
        } catch {
            fail(error)
        }
    }

    /// What the composer's "/" offers this session: its own skills a person may invoke.
    var slashCommands: [SlashCommand] {
        guard let session = detail?.session, let skills else { return [] }
        return SlashCommand.available(in: skills, for: session)
    }

    /// The web UI's "Copy full transcript": the whole transcript as text, on the pasteboard.
    func copyTranscript() async {
        do {
            UIPasteboard.general.string = try await api.transcriptText(id)
            notice = "Transcript copied"
            error = nil
            Haptics.success()
        } catch {
            fail(error)
        }
    }

    /// An action the server answers with a sentence rather than the session.
    func run(_ action: (ZimmerAPI) async throws -> String) async {
        do {
            notice = try await action(api)
            error = nil
            Haptics.success()
            await load()
        } catch {
            fail(error)
        }
    }
}

struct SessionDetailView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @StateObject private var model: SessionDetailModel
    @State private var choosingModel = false
    @State private var editingCatalog: CatalogKind?
    /// The web UI's log-level filter, as far as the conversation goes. Minimal by default:
    /// on a phone the tool traffic buries the words.
    @State private var level: ConversationLevel = .minimal
    @State private var editing: EditedText?
    @State private var renaming = false
    /// The web page's precedence field, in an alert as the rename is.
    @State private var editingPrecedence = false
    @State private var newPrecedence = ""
    @State private var showingLogs = false
    @State private var showingSubagents = false
    @State private var newTitle = ""
    /// The queued-turn banner's Force, waiting on its confirmation: the turn it would stop,
    /// and the server's words for what that costs.
    @State private var forcing: (victim: Int, confirm: String)?
    /// A banner's action is in flight.
    @State private var acting = false
    /// The snooze menu's *Custom…*, open in its sheet.
    @State private var customSnoozing = false
    /// A restart that takes this session over, waiting on its confirmation: the web UI's words
    /// for what it will do.
    @State private var confirmingRestart: String?
    @Environment(\.scenePhase) private var scenePhase
    /// Where the end of the conversation sits in the scroll view, and how tall the view is:
    /// new messages are followed only while the end is in view, so reading back is never
    /// yanked to the bottom. Read from geometry — in a stack that is not lazy, `onAppear` fires
    /// when a view is added, not when it scrolls into sight.
    @State private var endY: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    private var atEnd: Bool { endY <= viewportHeight + 80 }
    /// Scrolled to the newest message once, on the first load.
    @State private var openedAtNewest = false
    /// `-ZimmerFixtureOpenPanels`: the page opens at the details card with its folded rows
    /// open, so `ios/bin/ui-test` can photograph them.
    @State private var fixtureOpensPanels = false

    /// Short answers a person gives most often — on a phone, typing is the expensive part.
    static let quickReplies = ["Yes, go ahead.", "Merge it.", "Not yet — hold off."]

    /// The two long texts a session carries, each edited in a sheet.
    enum EditedText: String, Identifiable {
        case notes, goal
        var id: String { rawValue }
    }

    init(id: Int, api: ZimmerAPI) {
        _model = StateObject(wrappedValue: SessionDetailModel(id: id, api: api))
    }

    var body: some View {
        ScrollViewReader { proxy in
            page
                .onChange(of: model.conversation?.messages.last?.id) { _, _ in
                    guard model.conversation != nil else { return }
                    // Open at the newest message, as the web UI's transcript does; afterwards
                    // follow new ones only while the end is in view.
                    if !openedAtNewest {
                        openedAtNewest = true
                        let panels = fixtureOpensPanels
                        // After the layout that adds the messages, or the scroll can miss.
                        Task { @MainActor in
                            if panels {
                                proxy.scrollTo(Self.panelsAnchor, anchor: .top)
                            } else {
                                proxy.scrollTo(Self.endAnchor, anchor: .bottom)
                            }
                        }
                    } else if atEnd {
                        withAnimation { proxy.scrollTo(Self.endAnchor, anchor: .bottom) }
                    }
                }
        }
        // The web UI's page streams as the session moves; this reads again while it is on
        // screen, and at once when the app comes back to the front.
        .task(id: model.pollInterval) {
            while !Task.isCancelled {
                try? await Task.sleep(for: model.pollInterval)
                guard !Task.isCancelled else { return }
                // Only while this session is the screen in front, whatever SwiftUI keeps alive.
                guard app.path.last == model.id, app.tab == .sessions else { continue }
                await model.poll()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.poll() } }
        }
        .sheet(isPresented: $customSnoozing) {
            CustomSnoozeSheet { until in
                let label = until.formatted(date: .abbreviated, time: .shortened)
                let id = model.id
                return await model.apply("Snoozed until \(label)") { try await $0.setVisibility(id, .snoozed(until: until)) }
            }
        }
        .confirmationDialog(
            "Restart this session?",
            isPresented: Binding(get: { confirmingRestart != nil }, set: { if !$0 { confirmingRestart = nil } }),
            titleVisibility: .visible
        ) {
            Button("Restart") {
                let id = model.id
                Task { await model.apply("Restarted") { try await $0.restart(id) } }
            }
        } message: {
            // The web page's own confirm text for this session's restart.
            Text(confirmingRestart ?? "")
        }
    }

    static let endAnchor = "conversation.end"
    static let panelsAnchor = "detail.panels.anchor"

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let detail = model.detail {
                    header(detail)
                    // Why it is waiting and what to do about it: under the header, as the web
                    // page's header stacks them, above everything else.
                    WaitingBanners(banners: detail.waiting.banners, busy: acting) { perform($0) }
                    if let status = detail.statusSummary, status.summary != nil || status.generating == true || status.error != nil {
                        SummaryCard(status: status) {
                            Task { await model.run { try await $0.regenerateStatusSummary(model.id) } }
                        }
                    }
                    if detail.session.status == .failed, let failure = detail.session.metadata, failure.hasFailureDetails {
                        FailureCard(failure: failure)
                    }
                    // Goal check, goal, notes, MCP servers, hierarchy and human messages share one
                    // card, divided rather than stacked, as the web UI's panel group is.
                    DetailsCard(
                        detail: detail,
                        goal: model.configs?.goal(matching: detail.session.goal),
                        catalogRead: model.configs != nil,
                        expanded: fixtureOpensPanels,
                        edit: { editing = $0 },
                        editMcpServers: { editingCatalog = .mcpServers }
                    ) { junior, uncle in
                        Task { await model.detachUncle(junior, uncle: uncle) }
                    }
                    .id(Self.panelsAnchor)
                } else if model.isLoading {
                    LoadingState(text: "Loading session…").padding(.top, 60)
                }
                if let error = model.error { ErrorBanner(error: error) }
                if let conversation = model.shownConversation {
                    conversationSection(conversation)
                }
                // Under the conversation and above the composer, where the web UI puts them.
                if !model.undelivered.isEmpty {
                    UndeliveredCard(messages: model.undelivered)
                }
                if !model.queue.isEmpty {
                    QueueCard(model: model)
                }
                Color.clear
                    .frame(height: 1)
                    .id(Self.endAnchor)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .scrollView).minY } action: { endY = $0 }
            }
            .padding(.horizontal, Theme.margin)
            .padding(.vertical, 12)
            .animation(.snappy(duration: 0.3), value: model.detail == nil)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
        .background(Theme.ground)
        .navigationTitle(Text(verbatim: "#\(model.id)"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .modifier(QueuedTrashQuestion { $0.id == model.id && app.path.last == model.id })
        // Trashed — here, or after *Trash anyway* — the page goes and the board offers Undo.
        .onChange(of: app.undoable?.id) { _, trashed in
            if trashed == model.id { dismiss() }
        }
        .confirmationDialog(
            "Force a worker thread?",
            isPresented: Binding(get: { forcing != nil }, set: { if !$0 { forcing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Force", role: .destructive) {
                if let victim = forcing?.victim {
                    let id = model.id
                    act { await model.run { try await $0.forceStart(id, expectedVictimID: victim).message } }
                }
            }
            .accessibilityIdentifier("waiting.force.confirm")
        } message: {
            // The web page's own confirm text: whose turn stops, and what it loses.
            Text(forcing?.confirm ?? "")
        }
        .alert("Rename session", isPresented: $renaming) {
            TextField("Title", text: $newTitle)
                .accessibilityIdentifier("rename.field")
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                Task { await model.apply("Renamed") { try await $0.rename(model.id, title: title) } }
            }
            .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("Precedence", isPresented: $editingPrecedence) {
            TextField("Precedence", text: $newPrecedence)
                .keyboardType(.numbersAndPunctuation)
                .accessibilityIdentifier("precedence.field")
            Button("Cancel", role: .cancel) {}
            Button("Set") {
                guard let value = Precedence.parse(newPrecedence) else { return }
                let id = model.id
                Task { await model.apply("Precedence is now \(value).") { try await $0.setPrecedence(id, value) } }
            }
            .disabled(Precedence.parse(newPrecedence) == nil)
        } message: {
            // The web page's words beside the field: what the number does for this session.
            Text(model.detail?.session.precedenceHint ?? "")
        }
        .sheet(isPresented: $choosingModel) { modelSheet }
        .sheet(item: $editingCatalog) { kind in catalogSheet(kind) }
        .sheet(item: $editing) { field in
            switch field {
            case .notes:
                TextEditSheet(title: "Edit Notes", placeholder: "Notes for this session", initial: model.detail?.session.notes ?? "") { text in
                    await model.apply("Notes saved") { try await $0.updateNotes(model.id, notes: text) }
                }
            case .goal:
                // The web page's goal picker: the catalog's goals by name, or your own words.
                GoalPickerSheet(goals: model.configs?.goals ?? [], current: model.detail?.session.goal) { text in
                    let name = model.configs?.goal(matching: text)?.title
                    let done: String = text.isEmpty ? "Goal cleared" : name.map { "Goal: \($0)" } ?? "Goal updated"
                    let saved = await model.apply(done) { try await $0.updateGoal(model.id, goal: text) }
                    // The goal check rides on the session's page, not the PATCH's answer: read
                    // it again so it follows the goal, without holding the sheet open for it.
                    if saved { Task { await model.load() } }
                    return saved
                }
            }
        }
        .sheet(isPresented: $showingLogs) { SessionLogsView(id: model.id, api: model.api) }
        .sheet(isPresented: $showingSubagents) { SubagentsView(id: model.id, api: model.api) }
        .overlay(alignment: .bottom) {
            // Above the composer, which is a bottom inset.
            Toast(text: $model.notice, identifier: "followup.notice")
        }
        // The web UI's bubble, above the composer as its joystick is. A session started
        // from here threads under this one, as the bubble's `parent_session_id` does.
        .quickRouterCorner(parent: model.id)
        .safeAreaInset(edge: .bottom) {
            if model.detail?.acceptsFollowUp ?? false { composer }
        }
        .refreshable { await model.load() }
        .task {
            model.report = { [weak app] error in app?.noteError(error) }
            // Opening marks the session's notifications read: the Inbox badge follows.
            model.onOpened = { [weak app] in Task { await app?.refreshUnreadCount() } }
            if app.fixtureOpensPanels {
                app.fixtureOpensPanels = false
                fixtureOpensPanels = true
            }
            await model.load()
            if app.fixtureAttachesFile {
                app.fixtureAttachesFile = false
                model.attach([MessageAttachment(filename: "deploy.log", mediaType: "text/plain", data: Data("failed at step 3\n".utf8))])
            }
            if app.fixtureOpensCustomSnooze {
                app.fixtureOpensCustomSnooze = false
                customSnoozing = true
            }
            if app.fixtureTypesSlash {
                app.fixtureTypesSlash = false
                model.draft = "/"
            }
        }
        .onDisappear {
            // What changed here (a star, a snooze, a restore) shows on the list behind.
            Task { await app.sessionChanged() }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if let session = model.detail?.session {
                Button {
                    Task { await model.apply(session.isFavorite ? "Removed from favorites" : "Added to favorites") { try await $0.toggleFavorite(session.id) } }
                } label: {
                    Image(systemName: session.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(session.isFavorite ? Theme.gold : Theme.accent)
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel(session.isFavorite ? "Remove from Favorites" : "Add to Favorites")
                .accessibilityIdentifier("detail.favorite")
                actionsMenu(session)
                if session.status == .archived {
                    Button {
                        Task { await model.apply("Restored from trash") { try await $0.unarchive(session.id) } }
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .accessibilityLabel("Restore from Trash")
                    .accessibilityIdentifier("detail.restore")
                } else {
                    Button(role: .destructive) { Task { await app.trash(session) { model.fail($0) } } } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Move to trash")
                    .accessibilityIdentifier("detail.archive")
                }
            }
        }
    }

    // MARK: - Waiting banners

    /// A banner's one control: the call the server named, made the way the rest of the page
    /// makes it.
    private func perform(_ action: WaitingBanner.Action) {
        let id = model.id
        switch action {
        case let .updateSchedulingClass(_, priority):
            act { await model.reschedule(priority: priority) }
        case let .forceStart(_, victim, confirm):
            // Force stops somebody else's turn, so it is confirmed first, as on the web.
            forcing = (victim, confirm)
        case let .followUp(_, prompt):
            act { await model.run { try await $0.followUp(id, prompt: prompt).message } }
        case let .openInBrowser(_, path):
            if let url = app.webURL(path: path) { openURL(url) }
        }
    }

    /// One banner action at a time.
    private func act(_ work: @escaping @MainActor () async -> Void) {
        guard !acting else { return }
        acting = true
        Task {
            await work()
            acting = false
        }
    }

    // MARK: - Model and artifacts

    @ViewBuilder
    private var modelSheet: some View {
        if let session = model.detail?.session {
            ModelPickerSheet(session: session) { id in
                await model.apply("Model: \(id)") { try await $0.updateModel(session.id, model: id) }
            }
        }
    }

    @ViewBuilder
    private func catalogSheet(_ kind: CatalogKind) -> some View {
        if let session = model.detail?.session {
            CatalogEditorSheet(kind: kind, initial: kind.selection(in: session)) { values in
                var needsAuthorizing: [String] = []
                let saved = await model.apply("\(kind.label) updated — from the next turn") { api in
                    let change = try await api.updateSelection(session.id, kind, to: values)
                    needsAuthorizing = change.needsAuthorizing
                    return change.session
                }
                if saved, !needsAuthorizing.isEmpty {
                    // The server may park the session until these are authorized, which is a
                    // browser step (the MCP OAuth flow); say so rather than "updated".
                    model.notice = "Updated. Needs authorizing in the browser: \(needsAuthorizing.joined(separator: ", "))"
                }
                return saved
            }
        }
    }

    // MARK: - Header

    /// The web UI's phone header: the title, then one wrapping line of chips — status,
    /// priority, id and age, each PR, visibility — and one line of what runs it.
    private func header(_ detail: SessionDetail) -> some View {
        let session = detail.session
        return VStack(alignment: .leading, spacing: 7) {
            Text(session.displayTitle)
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("detail.title")
            FlowLayout(spacing: 6, rowSpacing: 6) {
                StatusBadge(status: session.status)
                    .accessibilityIdentifier("detail.status")
                if session.isPriority {
                    Text("Priority")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .foregroundStyle(Theme.danger)
                        .background(Theme.danger.opacity(0.12), in: Capsule())
                }
                Text(verbatim: idAndAge(session))
                    .font(Theme.mono)
                    .foregroundStyle(Theme.inkMute)
                ForEach(session.pullRequests.reversed()) { PullRequestChip(pullRequest: $0, compact: true) }
                VisibilityLabel(session: session)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.snooze)
                TrashExpiryLabel(session: session, withTime: true)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.inkSoft)
                    .accessibilityIdentifier("detail.trashexpiry")
            }
            metadataLine(session)
        }
        .padding(.top, 2)
    }

    private func idAndAge(_ session: SessionSummary) -> String {
        guard let date = session.updatedAt ?? session.createdAt else { return "#\(session.id)" }
        return "#\(session.id) · \(Format.age(date))"
    }

    /// Root · runtime · model · effort — the web UI's metadata block, on one quiet line.
    @ViewBuilder
    private func metadataLine(_ session: SessionSummary) -> some View {
        let line = metadataParts(session).joined(separator: " · ")
        if !line.isEmpty {
            // One Text, so a long line wraps as a sentence rather than as two columns.
            Text(verbatim: line)
                .font(.caption)
                .foregroundStyle(Theme.inkSoft)
                .lineLimit(2)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("detail.metadata")
        }
    }

    private func metadataParts(_ session: SessionSummary) -> [String] {
        var parts: [String] = []
        if let root = session.agentRoot { parts.append(root) }
        if let runtime = session.agentRuntime { parts.append(runtime) }
        if let model = session.model { parts.append(Format.modelName(model)) }
        if let effort = session.effort?.level { parts.append("effort \(effort)") }
        return parts
    }

    // MARK: - Actions

    /// The web UI's mobile "Session actions" sheet, as a menu, in its order; then the
    /// settings its desktop metadata block edits.
    private func actionsMenu(_ session: SessionSummary) -> some View {
        Menu {
            Section {
                Button { app.showingQuickRouter = true } label: { Label("Quick Router", systemImage: "sparkles") }
                Button { editing = .notes } label: { Label("Edit Notes", systemImage: "note.text") }
                Button { showingLogs = true } label: { Label("Show Logs", systemImage: "doc.plaintext") }
                Button { showingSubagents = true } label: { Label("Subagents", systemImage: "person.2") }
                if session.pullRequests.count == 1, let pr = session.pullRequests.first {
                    Button { openURL(pr.url) } label: { Label("View PR \(pr.label)", systemImage: "arrow.triangle.pull") }
                } else if !session.pullRequests.isEmpty {
                    Menu {
                        ForEach(session.pullRequests.reversed()) { pr in
                            Button("\(pr.label) (\(pr.state?.capitalized ?? "Unknown"))") { openURL(pr.url) }
                        }
                    } label: {
                        Label("View PR (\(session.pullRequests.count))", systemImage: "arrow.triangle.pull")
                    }
                }
            }
            Section {
                if session.boardVisibility == .visible {
                    Menu {
                        ForEach(VisibilityChange.snoozePresets()) { preset in
                            Button(preset.label) {
                                let until = preset.until.formatted(date: .abbreviated, time: .shortened)
                                Task { await model.apply("Snoozed until \(until)") { try await $0.setVisibility(session.id, .snoozed(until: preset.until)) } }
                            }
                        }
                        Button("Custom…") { customSnoozing = true }
                    } label: {
                        Label("Snooze until…", systemImage: "moon.zzz")
                    }
                    Button {
                        Task { await model.apply("Hidden") { try await $0.setVisibility(session.id, .hidden) } }
                    } label: {
                        Label("Hide", systemImage: "eye.slash")
                    }
                } else {
                    Button {
                        Task { await model.apply("Back on the board") { try await $0.setVisibility(session.id, .visible) } }
                    } label: {
                        Label("Put back on the board", systemImage: "eye")
                    }
                }
                Button {
                    Task { await model.run { try await $0.refreshTranscript(session.id) } }
                } label: {
                    Label("Refresh Transcript", systemImage: "arrow.triangle.2.circlepath")
                }
                Button {
                    Task { await model.copyTranscript() }
                } label: {
                    Label("Copy Transcript", systemImage: "doc.on.doc")
                }
                if session.status == .running {
                    Button {
                        Task { await model.apply("Paused") { try await $0.pause(session.id) } }
                    } label: {
                        Label("Pause Session", systemImage: "pause.circle")
                    }
                }
                if session.status == .waiting {
                    Button {
                        Task { await model.run { try await $0.startNow(session.id) } }
                    } label: {
                        Label("Start Now", systemImage: "play.circle")
                    }
                }
                if session.status == .failed || session.status == .needsInput {
                    Button {
                        // A failed session restarts at once; one waiting on you is taken over,
                        // so the web UI asks first.
                        if let confirmation = session.restartConfirmation(transcriptPresent: model.conversation.map { $0.total > 0 }) {
                            confirmingRestart = confirmation
                        } else {
                            Task { await model.apply("Restarted") { try await $0.restart(session.id) } }
                        }
                    } label: {
                        Label("Restart Session", systemImage: "arrow.clockwise.circle")
                    }
                }
            }
            Section {
                Button {
                    newTitle = session.title ?? ""
                    renaming = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button { editing = .goal } label: { Label("Modify Goal", systemImage: "flag") }
                Button { choosingModel = true } label: { Label("Model: \(session.model ?? "default")", systemImage: "cpu") }
                    .accessibilityIdentifier("detail.model")
                Menu {
                    ForEach(CatalogKind.allCases) { kind in
                        Button("\(kind.label) (\(kind.selection(in: session).count))") { editingCatalog = kind }
                    }
                } label: {
                    Label("MCP Servers, Skills, Hooks, Plugins", systemImage: "puzzlepiece.extension")
                }
                if let effort = session.effort, !effort.levels.isEmpty {
                    let modelDefault = effort.default.map { "Model default (\($0))" } ?? "Model default"
                    Menu {
                        Button {
                            Task { await model.apply("Effort: model default") { try await $0.updateEffort(session.id, effort: nil) } }
                        } label: {
                            choiceLabel(modelDefault, selected: !effort.isExplicit)
                        }
                        ForEach(effort.levels, id: \.self) { level in
                            Button {
                                Task { await model.apply("Effort: \(level)") { try await $0.updateEffort(session.id, effort: level) } }
                            } label: {
                                choiceLabel(level, selected: effort.isExplicit && effort.level == level)
                            }
                        }
                    } label: {
                        Label("Effort: \(effort.level ?? "default")", systemImage: "gauge.with.dots.needle.50percent")
                    }
                }
                // The web page's class select and precedence field, beside each other as there.
                Menu {
                    ForEach(SchedulingClassChoice.allCases) { choice in
                        Button {
                            choose(choice, for: session)
                        } label: {
                            choiceLabel(session.schedulingClassLabel(choice), selected: session.schedulingClassChoice == choice)
                        }
                    }
                } label: {
                    Label("Scheduling class: \(session.priorityClass ?? "priority")", systemImage: "clock")
                }
                Button {
                    // Opens on the value in force, as the web field does.
                    newPrecedence = session.precedence.map(String.init) ?? ""
                    editingPrecedence = true
                } label: {
                    Label("Precedence: \(session.precedence.map(String.init) ?? "—")", systemImage: "list.number")
                }
                heartbeatMenu(session)
                if model.detail?.statusSummary?.summary == nil {
                    Button {
                        Task { await model.run { try await $0.regenerateStatusSummary(session.id) } }
                    } label: {
                        Label("Generate Status Summary", systemImage: "text.badge.star")
                    }
                }
                if let url = app.webURL(for: session.id) {
                    Button { openURL(url) } label: { Label("Open in browser", systemImage: "safari") }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Session actions")
        .accessibilityIdentifier("detail.actions")
    }

    /// The web UI's heart and its popout: on or off, and "Beat every" from its intervals. When
    /// on, a session waiting for input is nudged to keep working toward its goal on that
    /// cadence. A new interval leaves the heartbeat on or off, as the popout's select does.
    private func heartbeatMenu(_ session: SessionSummary) -> some View {
        let enabled = session.heartbeatEnabled ?? false
        let interval = Binding<Int>(
            get: { session.heartbeatInterval },
            set: { seconds in
                Task {
                    await model.apply("Heartbeat every \(HeartbeatInterval.label(for: seconds))") { try await $0.setHeartbeatInterval(session.id, seconds: seconds) }
                }
            }
        )
        return Menu {
            Button {
                Task { await model.apply(enabled ? "Heartbeat off" : "Heartbeat on") { try await $0.setHeartbeat(session.id, enabled: !enabled) } }
            } label: {
                Label(enabled ? "Turn Off" : "Turn On", systemImage: enabled ? "heart.slash" : "heart")
            }
            Picker("Beat every", selection: interval) {
                ForEach(HeartbeatInterval.choices(including: session.heartbeatInterval)) { option in
                    Text(option.label).tag(option.seconds)
                }
            }
            .pickerStyle(.menu)
        } label: {
            Label(
                enabled ? "Heartbeat: every \(HeartbeatInterval.label(for: session.heartbeatInterval))" : "Heartbeat: off",
                systemImage: enabled ? "heart.fill" : "heart"
            )
        }
    }

    /// One of the class select's options, sent as the web select sends it: the class alone, the
    /// precedence left as it is. The one already chosen changes nothing. A change that makes a
    /// waiting session priority starts it, as the server's PATCH does on any change into
    /// priority. The banner's promotion and its head-of-the-queue demotion are other paths.
    private func choose(_ choice: SchedulingClassChoice, for session: SessionSummary) {
        guard choice != session.schedulingClassChoice else { return }
        Task { await model.setSchedulingClass(choice) }
    }

    @ViewBuilder
    private func choiceLabel(_ text: String, selected: Bool) -> some View {
        if selected { Label(text, systemImage: "checkmark") } else { Text(text) }
    }

    // MARK: - Conversation

    private func conversationSection(_ conversation: Conversation) -> some View {
        let shown = conversation.messages(at: level)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Conversation").themeLabel()
                Text(verbatim: "\(conversation.total)")
                    .font(Theme.label(11).monospacedDigit())
                    .foregroundStyle(Theme.inkMute)
                Spacer()
                if conversation.messages.contains(where: \.isToolTraffic) {
                    // The web UI's log-level select, on the conversation: Minimal, Condensed,
                    // Verbose. Its fourth level, Show Logs, is the logs screen in the menu.
                    Picker("Detail", selection: $level) {
                        ForEach(ConversationLevel.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .font(.caption.weight(.medium))
                    .tint(Theme.accent)
                    .accessibilityIdentifier("detail.level")
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 4)
            if conversation.truncated {
                // The web UI reads the transcript back as you scroll up; here a tap reads a
                // hundred more each time, back to the first message.
                HStack(spacing: 6) {
                    Text("The last \(conversation.total - conversation.firstPosition) of \(conversation.total).")
                    if conversation.firstPosition > 0 {
                        Button("Show earlier") { Task { await model.showEarlier() } }
                            .disabled(model.isLoadingEarlier)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.accent)
                            .accessibilityIdentifier("detail.earlier")
                    }
                }
                .font(.caption)
                .foregroundStyle(Theme.inkMute)
                .padding(.bottom, 4)
            }
            if conversation.messages.isEmpty {
                Text("No transcript yet.").font(.subheadline).foregroundStyle(Theme.inkMute).padding(.vertical, 8)
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, message in
                if index > 0 { Theme.rule.frame(height: 1).padding(.vertical, 8) }
                MessageBubble(message: message, folded: level.foldsToolTraffic)
            }
        }
    }

    // MARK: - Composer

    private var composer: some View {
        let running = model.detail?.session.status == .running
        let commands = slashMatches
        return VStack(spacing: 6) {
            if !commands.isEmpty {
                // The web composer's "/" typeahead, in the quick replies' place while it is open.
                SlashCommandList(matches: commands) { command in
                    model.draft = SlashCommand.inserting(command, into: model.draft)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Self.quickReplies, id: \.self) { reply in
                            Button { model.draft = reply } label: {
                                Pill(compact: true) { Text(reply) }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Theme.margin)
                }
                .padding(.horizontal, -Theme.margin)
            }
            if !model.attachments.isEmpty {
                AttachmentChips(attachments: $model.attachments)
            }
            HStack(alignment: .bottom, spacing: 8) {
                AttachMenu { model.attach($0, problems: $1) }
                // The hint lives in the placeholder: a running turn queues, and a touch and
                // hold on the button sends now instead.
                TextField(running ? "Queue message · hold send for now" : "Send message", text: $model.draft, axis: .vertical)
                    .lineLimit(1...5)
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(Theme.rule, lineWidth: 1))
                    .accessibilityIdentifier("followup.field")
                Button {
                    Task { await model.send() }
                } label: {
                    Image(systemName: model.isSending ? "hourglass" : (running ? "text.badge.plus" : "arrow.up"))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(canSend ? Color.white : Theme.inkMute)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(canSend ? Theme.accentFill : Theme.well))
                        .contentTransition(.symbolEffect(.replace))
                        .animation(.snappy(duration: 0.2), value: canSend)
                }
                .disabled(!canSend)
                .accessibilityLabel(running ? "Queue" : "Send")
                .accessibilityHint(running ? "Touch and hold to send now, ending the current turn." : "")
                .accessibilityIdentifier("followup.send")
                .contextMenu {
                    if running {
                        Button {
                            Task { await model.send(now: true) }
                        } label: {
                            Label("Send Now — ends the current turn", systemImage: "bolt.fill")
                        }
                        .accessibilityIdentifier("followup.sendnow")
                    }
                }
            }
        }
        .padding(.horizontal, Theme.margin)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background {
            Theme.ground
                .overlay(alignment: .top) { Theme.rule.frame(height: 1) }
                .ignoresSafeArea(edges: .bottom)
        }
    }

    /// The session's skills matching a "/" being typed at the end of the draft; none otherwise.
    private var slashMatches: [SlashCommand] {
        guard let query = SlashCommand.query(in: model.draft) else { return [] }
        return SlashCommand.matches(query, in: model.slashCommands)
    }

    private var canSend: Bool {
        !model.isSending && !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// "Where things stand": the one card that leads the page, with a gold rule down its edge.
/// Under the text, how fresh it is — the web UI's "up to date as of …" or "3 messages
/// since summary generated" — and Regenerate as a glyph.
private struct SummaryCard: View {
    let status: StatusSummary
    let regenerate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Where things stand").themeLabel()
                Spacer()
                if status.generating == true {
                    ProgressView().controlSize(.mini)
                } else {
                    Button(action: regenerate) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .accessibilityLabel("Regenerate")
                    .accessibilityIdentifier("detail.summary.regenerate")
                }
            }
            if let text = status.summary {
                Text(text).font(.callout).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
            } else if status.generating == true {
                Text("Writing a status summary…").font(.callout).foregroundStyle(Theme.inkSoft)
            }
            if let error = status.error, status.generating != true {
                Text("The last attempt failed: \(error)").font(.caption).foregroundStyle(Theme.warning)
            }
            if status.summary != nil, let freshness {
                Text(freshness)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(status.isCurrent ? Theme.inkMute : Theme.warning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .themeCard(radius: Theme.smallRadius)
        .overlay(alignment: .leading) {
            Theme.gold.frame(width: 3).padding(.vertical, 12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.summary")
    }

    private var freshness: String? {
        let since = status.messagesSinceGenerated ?? 0
        let age = status.generatedAt.map { "as of \(Format.age($0))" }
        switch (since, age) {
        case (0, let age?): return age
        case (0, nil): return nil
        case (let n, let age?): return "\(age) · \(n) new since"
        case (let n, nil): return "\(n) new since"
        }
    }
}

/// Why a failed session failed: the web UI's failure details, which its phone layout keeps
/// above the panels. Reason, exception, exit status.
private struct FailureCard: View {
    let failure: SessionMetadata

    var body: some View {
        let colors = Theme.status(.failed)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Why it failed").themeLabel(color: colors.text)
                if let reason = failure.failureReason {
                    Text(reason.replacingOccurrences(of: "_", with: " ")).font(Theme.label(11)).foregroundStyle(colors.text)
                }
                if let status = failure.exitStatus {
                    Text(verbatim: "· exit \(status)").font(Theme.label(11).monospacedDigit()).foregroundStyle(colors.text)
                }
            }
            if let message = failure.exceptionMessage {
                Text(message).font(.subheadline).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let kind = failure.exceptionClass {
                Text(kind).font(Theme.mono).foregroundStyle(Theme.inkSoft)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .themeCard(radius: Theme.smallRadius, fill: colors.fill)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.failure")
    }
}

/// A sheet with one text editor: the notes. `save` reports whether the server took it; the
/// sheet stays open with the text when it did not.
private struct TextEditSheet: View {
    let title: String
    let placeholder: String
    let initial: String
    let save: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var saving = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder).foregroundStyle(Theme.inkMute).padding(.top, 8).padding(.leading, 5)
                }
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .accessibilityIdentifier("edit.text")
            }
            .padding(12)
            .themeCard(radius: Theme.smallRadius)
            .padding()
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Theme.ground)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") {
                        Task {
                            saving = true
                            let saved = await save(text.trimmingCharacters(in: .whitespacesAndNewlines))
                            saving = false
                            if saved { dismiss() }
                        }
                    }
                    .disabled(saving)
                    .accessibilityIdentifier("edit.save")
                }
            }
            .onAppear {
                text = initial
                focused = true
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct MessageBubble: View {
    let message: ConversationMessage
    /// Tool traffic cut to a line: the Condensed level.
    var folded = false

    var body: some View {
        let fromAgent = message.role == .assistant
        let folds = message.isToolTraffic && folded
        // Parsed once, for the text and for whether a Copy button has to be reachable.
        let segments = folds ? [] : MessageSegment.segments(of: message.content)
        let hasCode = segments.contains(where: \.isCode)
        VStack(alignment: fromAgent ? .leading : .trailing, spacing: 3) {
            HStack(spacing: 4) {
                Text(message.isToolTraffic ? "Tool" : (fromAgent ? "Agent" : "You"))
                if let date = message.timestamp {
                    // Not uppercased with the label: "41m", not "41M".
                    Text(verbatim: "· \(Format.age(date))").monospacedDigit().textCase(nil)
                }
            }
            .themeLabel(size: 10, color: Theme.inkMute)
            Group {
                if folds {
                    Text(message.condensedLine)
                        .font(Theme.mono)
                        .foregroundStyle(Theme.inkSoft)
                        .lineLimit(1)
                } else if message.isToolTraffic {
                    // The server writes tool traffic as markdown too (`**Using tool: Bash**`
                    // over a fenced block), so it renders the same way, in the monospaced face.
                    MarkdownText(segments: segments, proseFont: Theme.mono, proseColor: Theme.inkSoft)
                } else {
                    MarkdownText(segments: segments)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, fromAgent && !message.isToolTraffic ? 0 : 12)
            .padding(.vertical, fromAgent && !message.isToolTraffic ? 0 : 8)
            .background(bubble(fromAgent: fromAgent))
            .textSelection(.enabled)
        }
        // A reply from you sits to the right and stops short of the far edge, as in Messages.
        .padding(.leading, fromAgent ? 0 : 36)
        .frame(maxWidth: .infinity, alignment: fromAgent ? .leading : .trailing)
        // One element to VoiceOver, unless a code block's Copy button has to be reachable.
        .accessibilityElement(children: hasCode ? .contain : .combine)
        .accessibilityIdentifier("detail.message.\(message.id)")
    }

    /// The agent's words as plain text, as Motet draws prose; yours on the accent's wash;
    /// tool traffic in a quiet well.
    @ViewBuilder
    private func bubble(fromAgent: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
        if message.isToolTraffic {
            shape.fill(Theme.well)
        } else if fromAgent {
            Color.clear
        } else {
            shape.fill(Theme.accent.opacity(0.14))
        }
    }
}

/// A message's text as the web UI renders it: prose as inline markdown (emphasis, code
/// spans, links, list markers kept as typed), fenced code blocks in the monospaced face on
/// a well. Markdown that does not parse is shown as it was written.
struct MarkdownText: View {
    /// The text, already cut at its fences (`MessageSegment.segments(of:)`).
    let segments: [MessageSegment]
    var proseFont: Font = .subheadline
    var proseColor: Color = Theme.ink

    init(segments: [MessageSegment], proseFont: Font = .subheadline, proseColor: Color = Theme.ink) {
        self.segments = segments
        self.proseFont = proseFont
        self.proseColor = proseColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case let .prose(prose):
                    Text(Self.attributed(prose))
                        .font(proseFont)
                        .foregroundStyle(proseColor)
                case let .code(code, _):
                    CodeBlock(code: code)
                }
            }
        }
    }

    /// Inline-only, keeping line breaks and list markers: a paragraph stays a paragraph.
    static func attributed(_ prose: String) -> AttributedString {
        MarkdownInline.attributed(prose)
    }
}

/// A fenced code block as the web's `code_block_controller.js` draws one: the code in the
/// monospaced face on a well, scrolling sideways rather than wrapping, with a Copy button in
/// its corner that puts the code on the pasteboard and shows a check for a moment. The web
/// also colours the code by language (Rouge); here it is one colour.
struct CodeBlock: View {
    let code: String
    /// Bumped by each tap, so the check's reset follows the latest tap rather than the first.
    @State private var copies = 0
    @State private var copied = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(Theme.mono)
                .foregroundStyle(Theme.ink)
                .padding(.leading, 10)
                // Room for the button at the end of the line, so the last characters can be
                // scrolled out from under it.
                .padding(.trailing, 40)
                .padding(.vertical, 8)
        }
        .background(Theme.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Button {
                UIPasteboard.general.string = code
                copied = true
                copies += 1
                Haptics.success()
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(copied ? Theme.success : Theme.inkSoft)
                    .frame(width: 30, height: 30)
                    .background(Theme.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(copied ? "Copied" : "Copy code")
            .accessibilityIdentifier("code.copy")
        }
        // A new tap cancels the wait before it, so the check stays two seconds past the last.
        .task(id: copies) {
            guard copies > 0 else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}
