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

    @Published private(set) var detail: SessionDetail?
    @Published private(set) var conversation: Conversation?
    /// How far back the conversation reads: a hundred at first, a hundred more on *Show
    /// earlier*, up to what the server returns in one read.
    @Published private(set) var conversationLimit = Conversation.pageSize
    @Published private(set) var isLoading = false
    @Published private(set) var isSending = false
    @Published var error: ZimmerError?
    @Published var notice: String?
    @Published var draft = ""
    /// The messages waiting for the turn in flight to end (`QueueCard`).
    @Published var queue: [QueuedMessage] = []
    /// Photos and files going with the next message.
    @Published var attachments: [MessageAttachment] = []

    init(id: Int, api: ZimmerAPI) {
        self.id = id
        self.api = api
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            detail = try await api.session(id)
            conversation = try await api.conversation(id, limit: conversationLimit)
            // The queue is a panel, not the page: one that will not load keeps what it last
            // showed rather than failing the session — unless the sign-in has ended.
            do {
                queue = try await api.queue(id)
            } catch ZimmerError.unauthorized {
                report(.unauthorized)
            } catch {}
            error = nil
        } catch {
            fail(error)
        }
    }

    /// Widen the window by a page and read again: the web UI's transcript reading back as
    /// you scroll up.
    func showEarlier() async {
        guard conversationLimit < Conversation.maxLimit else { return }
        conversationLimit = min(conversationLimit + Conversation.pageSize, Conversation.maxLimit)
        do {
            conversation = try await api.conversation(id, limit: conversationLimit)
            error = nil
        } catch {
            fail(error)
        }
    }

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
    func attach(_ new: [MessageAttachment], unreadable: [String] = []) {
        var refusals = unreadable.map { "\($0) couldn't be read." }
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

    func archive() async -> Bool {
        do {
            _ = try await api.archive(id)
            Haptics.success()
            return true
        } catch {
            fail(error)
            return false
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
        } catch {
            fail(error)
        }
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
    @State private var confirmingArchive = false
    @State private var choosingModel = false
    @State private var editingCatalog: CatalogKind?
    /// The web UI's log-level filter, as far as the conversation goes. Minimal by default:
    /// on a phone the tool traffic buries the words.
    @State private var level: ConversationLevel = .minimal
    @State private var editing: EditedText?
    @State private var renaming = false
    @State private var showingLogs = false
    @State private var showingSubagents = false
    @State private var newTitle = ""

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
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let detail = model.detail {
                    header(detail)
                    if let status = detail.statusSummary, status.summary != nil || status.generating == true || status.error != nil {
                        SummaryCard(status: status) {
                            Task { await model.run { try await $0.regenerateStatusSummary(model.id) } }
                        }
                    }
                    if detail.session.status == .failed, let failure = detail.session.metadata, failure.hasFailureDetails {
                        FailureCard(failure: failure)
                    }
                    // Goal check, goal, notes, hierarchy and human messages share one card,
                    // divided rather than stacked, as the web UI's panel group is.
                    DetailsCard(detail: detail, edit: { editing = $0 }) { junior, uncle in
                        Task { await model.detachUncle(junior, uncle: uncle) }
                    }
                } else if model.isLoading {
                    LoadingState(text: "Loading session…").padding(.top, 60)
                }
                if let error = model.error { ErrorBanner(error: error) }
                if let conversation = model.conversation {
                    conversationSection(conversation)
                }
                // Under the conversation and above the composer, where the web UI puts it.
                if !model.queue.isEmpty {
                    QueueCard(model: model)
                }
            }
            .padding(.horizontal, Theme.margin)
            .padding(.vertical, 12)
            .animation(.snappy(duration: 0.3), value: model.detail == nil)
        }
        .background(Theme.ground)
        .navigationTitle(Text(verbatim: "#\(model.id)"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .confirmationDialog("Move to trash?", isPresented: $confirmingArchive, titleVisibility: .visible) {
            Button("Trash", role: .destructive) {
                Task {
                    if await model.archive() {
                        await app.sessionChanged()
                        dismiss()
                    }
                }
            }
        } message: {
            Text("It moves to the trash. You can restore it from Archived.")
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
        .sheet(isPresented: $choosingModel) { modelSheet }
        .sheet(item: $editingCatalog) { kind in catalogSheet(kind) }
        .sheet(item: $editing) { field in
            TextEditSheet(
                title: field == .notes ? "Edit Notes" : "Modify Goal",
                placeholder: field == .notes ? "Notes for this session" : "When is this session done?",
                initial: (field == .notes ? model.detail?.session.notes : model.detail?.session.goal) ?? ""
            ) { text in
                switch field {
                case .notes: return await model.apply("Notes saved") { try await $0.updateNotes(model.id, notes: text) }
                case .goal: return await model.apply(text.isEmpty ? "Goal cleared" : "Goal updated") { try await $0.updateGoal(model.id, goal: text) }
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
            await model.load()
            if app.fixtureAttachesFile {
                app.fixtureAttachesFile = false
                model.attach([MessageAttachment(filename: "deploy.log", mediaType: "text/plain", data: Data("failed at step 3\n".utf8))])
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
                    Button(role: .destructive) { confirmingArchive = true } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Move to trash")
                    .accessibilityIdentifier("detail.archive")
                }
            }
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
                        Task { await model.apply("Restarted") { try await $0.restart(session.id) } }
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
                            effortLabel(modelDefault, selected: !effort.isExplicit)
                        }
                        ForEach(effort.levels, id: \.self) { level in
                            Button {
                                Task { await model.apply("Effort: \(level)") { try await $0.updateEffort(session.id, effort: level) } }
                            } label: {
                                effortLabel(level, selected: effort.isExplicit && effort.level == level)
                            }
                        }
                    } label: {
                        Label("Effort: \(effort.level ?? "default")", systemImage: "gauge.with.dots.needle.50percent")
                    }
                }
                if session.isPriority {
                    Button {
                        Task { await model.reschedule(priority: false) }
                    } label: {
                        Label("Demote to spot", systemImage: "arrow.down.circle")
                    }
                } else {
                    Button {
                        Task { await model.reschedule(priority: true) }
                    } label: {
                        Label("Promote to priority", systemImage: "arrow.up.circle")
                    }
                }
                Button {
                    let enabled = !(session.heartbeatEnabled ?? false)
                    Task { await model.apply(enabled ? "Heartbeat on" : "Heartbeat off") { try await $0.setHeartbeat(session.id, enabled: enabled) } }
                } label: {
                    Label((session.heartbeatEnabled ?? false) ? "Turn Heartbeat Off" : "Turn Heartbeat On", systemImage: "heart")
                }
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

    @ViewBuilder
    private func effortLabel(_ text: String, selected: Bool) -> some View {
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
                // hundred more, up to the server's one-read cap.
                HStack(spacing: 6) {
                    Text("The last \(conversation.messages.count) of \(conversation.total).")
                    if model.conversationLimit < Conversation.maxLimit {
                        Button("Show earlier") { Task { await model.showEarlier() } }
                            .font(.caption.weight(.medium))
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
        return VStack(spacing: 6) {
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
            if !model.attachments.isEmpty {
                AttachmentChips(attachments: $model.attachments)
            }
            HStack(alignment: .bottom, spacing: 8) {
                AttachMenu { model.attach($0, unreadable: $1) }
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

/// Goal check, goal, notes, hierarchy and human messages: one card, hairlines between the
/// rows. Goal and notes clamp to two lines and open on a tap; the hierarchy folds when it
/// is wide, the human messages always, each saying in its closed row what it holds.
private struct DetailsCard: View {
    let detail: SessionDetail
    let edit: (SessionDetailView.EditedText) -> Void
    let detach: (Int, Int) -> Void

    private enum Row: Identifiable {
        case goalCheck(GoalCheck)
        case goal(String)
        case notes(String)
        case hierarchy(SessionHierarchy)
        case humanMessages([HumanMessage])

        var id: String {
            switch self {
            case .goalCheck: return "goalCheck"
            case .goal: return "goal"
            case .notes: return "notes"
            case .hierarchy: return "hierarchy"
            case .humanMessages: return "humanMessages"
            }
        }
    }

    private var rows: [Row] {
        var rows: [Row] = []
        if let check = detail.goalCheck, !check.criteria.isEmpty { rows.append(.goalCheck(check)) }
        if let goal = detail.session.goal, !goal.isEmpty { rows.append(.goal(goal)) }
        if detail.session.hasNotes, let notes = detail.session.notes { rows.append(.notes(notes)) }
        if let hierarchy = detail.hierarchy, hierarchy.isWorthShowing { rows.append(.hierarchy(hierarchy)) }
        if !detail.humanMessages.isEmpty { rows.append(.humanMessages(detail.humanMessages)) }
        return rows
    }

    var body: some View {
        let rows = rows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Theme.rule.frame(height: 1) }
                    view(for: row)
                        .padding(.vertical, 9)
                        .padding(.horizontal, 12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .themeCard(radius: Theme.smallRadius)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("detail.panels")
        }
    }

    @ViewBuilder
    private func view(for row: Row) -> some View {
        switch row {
        case let .goalCheck(check):
            GoalCheckRow(check: check)
        case let .goal(goal):
            ClampedTextRow(title: "Goal", text: goal, identifier: "detail.goal") { edit(.goal) }
        case let .notes(notes):
            ClampedTextRow(title: "Notes", text: notes, identifier: "detail.notes") { edit(.notes) }
        case let .hierarchy(hierarchy):
            HierarchyRow(hierarchy: hierarchy, detach: detach)
        case let .humanMessages(messages):
            HumanMessagesRow(messages: messages)
        }
    }
}

/// The web UI's Goal check panel: the verdict, then one line per criterion.
private struct GoalCheckRow: View {
    let check: GoalCheck

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("Goal check").themeLabel()
                Text(check.verdict.capitalized)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .foregroundStyle(Self.verdictColors(check.verdict).text)
                    .background(Self.verdictColors(check.verdict).fill, in: Capsule())
                Text(verbatim: "\(check.metCount) of \(check.criteria.count) met")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.inkMute)
                Spacer()
            }
            ForEach(check.criteria) { criterion in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Self.mark(criterion.status).0)
                        .font(.caption.weight(.bold).monospaced())
                        .foregroundStyle(Self.mark(criterion.status).1)
                        .frame(width: 12)
                    Text(criterion.label).font(.subheadline).foregroundStyle(Theme.ink)
                    if let detail = criterion.detail, !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(Theme.inkMute).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            if check.provisional {
                Text("Still working: unmet means not yet.").font(.caption2).foregroundStyle(Theme.inkMute)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.goalcheck")
    }

    /// `_goal_check_panel.html.erb`'s marks and colours.
    static func mark(_ status: String) -> (String, Color) {
        switch status {
        case "met": return ("✓", Theme.success)
        case "unmet": return ("✗", Theme.danger)
        case "pending": return ("…", Theme.ci("pending"))
        default: return ("?", Theme.inkMute)
        }
    }

    static func verdictColors(_ verdict: String) -> Theme.StatusColors {
        switch verdict {
        case "met": return Theme.status(.running)
        case "unmet": return Theme.status(.failed)
        default: return Theme.status(.waiting)
        }
    }
}

/// A titled block of text with an Edit button, clamped to two lines until tapped: the
/// goal, the notes.
private struct ClampedTextRow: View {
    let title: String
    let text: String
    let identifier: String
    let edit: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).themeLabel()
                Spacer()
                Button("Edit", action: edit).font(.caption.weight(.medium))
            }
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
                .lineLimit(expanded ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

/// The web UI's hierarchy panel: who spawned this session and what it spawned, indented by
/// depth. Every other session in it opens on a tap. A tree of more than four folds, and
/// its closed row says how big it is.
private struct HierarchyRow: View {
    let hierarchy: SessionHierarchy
    /// Remove an "also senior" edge: (junior, uncle).
    let detach: (Int, Int) -> Void
    @State private var open: Bool
    @State private var detaching: (junior: Int, uncle: Int)?

    init(hierarchy: SessionHierarchy, detach: @escaping (Int, Int) -> Void) {
        self.hierarchy = hierarchy
        self.detach = detach
        _open = State(initialValue: hierarchy.nodes.count <= 4)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(hierarchy.nodes) { node in
                    VStack(alignment: .leading, spacing: 2) {
                        if node.current {
                            row(node).fontWeight(.semibold)
                        } else {
                            NavigationLink(value: node.id) { row(node) }
                                .buttonStyle(.plain)
                        }
                        // Beside the link, not in it, so a detach is never taken as opening the session.
                        if !node.uncles.isEmpty { seniors(node) }
                    }
                }
                if hierarchy.truncated {
                    Text("Only part of the hierarchy is shown.").font(.caption).foregroundStyle(Theme.inkSoft)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Text("Hierarchy").themeLabel()
                Text(summary).font(.caption2.monospacedDigit()).foregroundStyle(Theme.inkMute)
            }
        }
        .tint(Theme.inkMute)
        .confirmationDialog(
            detaching.map { "Remove #\($0.uncle) as an additional senior of #\($0.junior)?" } ?? "",
            isPresented: Binding(get: { detaching != nil }, set: { if !$0 { detaching = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let edge = detaching { detach(edge.junior, edge.uncle) }
            }
        } message: {
            Text("Both sessions stop pulling in the other's human messages through this edge. Spawn parents are untouched, and both timelines record the removal.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.hierarchy")
    }

    /// "7 sessions · parent #1040" — what the closed row says. The parent is the nearest
    /// node above the current one that sits one level shallower, in draw order.
    private var summary: String {
        var parts = ["\(hierarchy.nodes.count) sessions"]
        if let index = hierarchy.nodes.firstIndex(where: \.current) {
            let current = hierarchy.nodes[index]
            if current.depth > 0, let parent = hierarchy.nodes[..<index].last(where: { $0.depth == current.depth - 1 }) {
                parts.append("parent #\(parent.id)")
            }
        }
        return parts.joined(separator: " · ")
    }

    private func row(_ node: SessionHierarchy.Node) -> some View {
        HStack(spacing: 6) {
            StatusDot(status: node.status, size: 7)
            Text(node.displayTitle).lineLimit(1).foregroundStyle(Theme.ink)
            Spacer(minLength: 4)
            Text(verbatim: "#\(node.id)").font(Theme.mono).foregroundStyle(Theme.inkMute)
            if !node.current {
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(Theme.inkMute)
            }
        }
        .font(.subheadline)
        .padding(.leading, CGFloat(min(node.depth, 6)) * 12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("hierarchy.node.\(node.id)")
    }

    /// The web UI's amber "also senior" chips: the sessions that queued or interrupted this
    /// one, each with its own detach.
    private func seniors(_ node: SessionHierarchy.Node) -> some View {
        HStack(spacing: 4) {
            Text("also senior:")
            ForEach(node.uncles, id: \.self) { uncle in
                // As on the web: the number opens that session, only the × detaches.
                HStack(spacing: 2) {
                    NavigationLink(value: uncle) { Text(verbatim: "#\(uncle)").underline() }
                        .buttonStyle(.plain)
                    Button {
                        detaching = (node.id, uncle)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove #\(uncle) as an additional senior of #\(node.id)")
                    .accessibilityIdentifier("hierarchy.uncle.\(node.id).\(uncle)")
                }
            }
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(Theme.status(.failed).text)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Theme.status(.failed).fill, in: Capsule())
        .padding(.leading, CGFloat(min(node.depth, 6)) * 12 + 14)
    }
}

/// The web UI's Human messages panel: what people said to this session and its family,
/// folded, with who and through which channel on each.
private struct HumanMessagesRow: View {
    let messages: [HumanMessage]
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(messages) { message in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: provenance(message))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Theme.inkMute)
                        Text(message.content)
                            .font(.subheadline)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(4)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Text("Human messages").themeLabel()
                Text(verbatim: "\(messages.count)").font(.caption2.monospacedDigit()).foregroundStyle(Theme.inkMute)
            }
        }
        .tint(Theme.inkMute)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.humanmessages")
    }

    private func provenance(_ message: HumanMessage) -> String {
        var parts: [String] = []
        if let author = message.author { parts.append(author) }
        if let channel = message.channelLabel { parts.append(channel) }
        if let id = message.authoredInSessionID { parts.append("#\(id)") }
        if let date = message.occurredAt { parts.append(Format.age(date)) }
        return parts.joined(separator: " · ")
    }
}

/// A sheet with one text editor: notes and goal. `save` reports whether the server took it;
/// the sheet stays open with the text when it did not.
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
                if message.isToolTraffic {
                    Text(message.content)
                        .font(Theme.mono)
                        .foregroundStyle(Theme.inkSoft)
                        .lineLimit(folded ? 1 : nil)
                } else {
                    MarkdownText(message.content)
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
        .accessibilityElement(children: .combine)
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
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MessageSegment.segments(of: text).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case let .prose(prose):
                    Text(Self.attributed(prose))
                        .font(.subheadline)
                        .foregroundStyle(Theme.ink)
                case let .code(code, _):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code)
                            .font(Theme.mono)
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }
                    .background(Theme.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }

    /// Inline-only, keeping line breaks and list markers: a paragraph stays a paragraph.
    static func attributed(_ prose: String) -> AttributedString {
        (try? AttributedString(markdown: prose, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(prose)
    }
}
