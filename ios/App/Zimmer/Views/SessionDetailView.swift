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
            conversation = try await api.conversation(id)
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
    @State private var showingToolTraffic = false
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
            VStack(alignment: .leading, spacing: 16) {
                if let detail = model.detail {
                    header(detail)
                    if !detail.session.pullRequests.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(detail.session.pullRequests.reversed()) { PullRequestChip(pullRequest: $0) }
                            }
                        }
                    }
                    if let status = detail.statusSummary, status.summary != nil || status.generating == true || status.error != nil {
                        SummaryCard(status: status) {
                            Task { await model.run { try await $0.regenerateStatusSummary(model.id) } }
                        }
                    }
                    if let goal = detail.session.goal, !goal.isEmpty {
                        TextCard(title: "Goal", text: goal, identifier: "detail.goal") { editing = .goal }
                    }
                    if detail.session.hasNotes, let notes = detail.session.notes {
                        TextCard(title: "Notes", text: notes, identifier: "detail.notes") { editing = .notes }
                    }
                    if let hierarchy = detail.hierarchy, hierarchy.isWorthShowing {
                        HierarchyCard(hierarchy: hierarchy) { junior, uncle in
                            Task { await model.detachUncle(junior, uncle: uncle) }
                        }
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
        // The web UI's bubble, above the composer as its joystick is.
        .quickRouterCorner()
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

    private func header(_ detail: SessionDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                StatusBadge(status: detail.session.status)
                    .accessibilityIdentifier("detail.status")
                if detail.session.isPriority {
                    Text("Priority")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .foregroundStyle(Theme.danger)
                        .background(Theme.danger.opacity(0.12), in: Capsule())
                }
                VisibilityLabel(session: detail.session)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.snooze)
            }
            Text(detail.session.displayTitle)
                .font(Theme.title())
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("detail.title")
            metadataLine(detail.session)
                .font(Theme.mono)
                .foregroundStyle(Theme.inkSoft)
        }
        .padding(.top, 4)
    }

    /// Runtime, model, effort, root and age — the web UI's metadata block, on one line.
    private func metadataLine(_ session: SessionSummary) -> some View {
        var parts: [String] = []
        if let root = session.agentRoot { parts.append(root) }
        if let runtime = session.agentRuntime { parts.append(runtime) }
        if let model = session.model { parts.append(model) }
        if let effort = session.effort?.level { parts.append("effort \(effort)") }
        let joined = parts.joined(separator: " · ")
        // One Text, so a long line wraps as a sentence rather than as two columns.
        return Group {
            if let date = session.updatedAt ?? session.createdAt {
                let age = date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
                Text(verbatim: joined.isEmpty ? age : "\(joined) · \(age)")
            } else {
                Text(verbatim: joined)
            }
        }
        .lineLimit(2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("detail.metadata")
    }

    // MARK: - Actions

    /// The web UI's mobile "Session actions" sheet, as a menu, in its order; then the
    /// settings its desktop metadata block edits.
    private func actionsMenu(_ session: SessionSummary) -> some View {
        Menu {
            Section {
                Button { app.showingQuickRouter = true } label: { Label("Quick Router", systemImage: "square.and.pencil") }
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Conversation").themeLabel()
                Spacer()
                if conversation.messages.contains(where: \.isToolTraffic) {
                    Toggle("Tool calls", isOn: $showingToolTraffic)
                        .toggleStyle(.button)
                        .font(.footnote.weight(.medium))
                }
            }
            .padding(.top, 8)
            if conversation.truncated {
                Text("Showing the last \(conversation.messages.count) of \(conversation.total) messages.")
                    .font(.caption)
                    .foregroundStyle(Theme.inkSoft)
            }
            if conversation.messages.isEmpty {
                Text("No transcript yet.").font(.subheadline).foregroundStyle(Theme.inkMute)
            }
            ForEach(conversation.messages.filter { showingToolTraffic || !$0.isToolTraffic }) { message in
                MessageBubble(message: message)
            }
        }
    }

    // MARK: - Composer

    private var composer: some View {
        let running = model.detail?.session.status == .running
        return VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.quickReplies, id: \.self) { reply in
                        Button { model.draft = reply } label: {
                            Pill { Text(reply) }
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
                TextField(running ? "Queue Message" : "Send Message", text: $model.draft, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).strokeBorder(Theme.rule, lineWidth: 1))
                    .accessibilityIdentifier("followup.field")
                Button {
                    Task { await model.send() }
                } label: {
                    Image(systemName: model.isSending ? "hourglass" : (running ? "text.badge.plus" : "arrow.up"))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(canSend ? Color.white : Theme.inkMute)
                        .frame(width: 36, height: 36)
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
            if running {
                Text("A turn is running: this queues. Touch and hold to send now.")
                    .font(.caption2)
                    .foregroundStyle(Theme.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, Theme.margin)
        .padding(.top, 10)
        .padding(.bottom, 8)
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

private struct SummaryCard: View {
    let status: StatusSummary
    let regenerate: () -> Void

    var body: some View {
        ThemeCard(title: "Where things stand") {
            if status.generating == true {
                ProgressView().controlSize(.small)
            } else {
                Button("Regenerate", action: regenerate)
                    .accessibilityIdentifier("detail.summary.regenerate")
            }
        } content: {
            if let text = status.summary {
                Text(text).foregroundStyle(Theme.ink)
            } else if status.generating == true {
                Text("Writing a status summary…").foregroundStyle(Theme.inkSoft)
            }
            if let error = status.error, status.generating != true {
                Text("The last attempt failed: \(error)").font(.caption).foregroundStyle(Theme.warning)
            }
        }
        // The one card that leads the page: a gold rule down its edge, the mark's signature.
        .overlay(alignment: .leading) {
            Theme.gold.frame(width: 3).padding(.vertical, 16)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.summary")
    }
}

/// The web UI's hierarchy panel: who spawned this session and what it spawned, indented by
/// depth. Every other session in it opens on a tap.
private struct HierarchyCard: View {
    let hierarchy: SessionHierarchy
    /// Remove an "also senior" edge: (junior, uncle).
    let detach: (Int, Int) -> Void
    @State private var detaching: (junior: Int, uncle: Int)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hierarchy").themeLabel()
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .themeCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.hierarchy")
    }

    private func row(_ node: SessionHierarchy.Node) -> some View {
        HStack(spacing: 6) {
            StatusDot(status: node.status)
            Text(node.displayTitle).lineLimit(1).foregroundStyle(Theme.ink)
            Spacer(minLength: 4)
            Text(verbatim: "#\(node.id)").font(Theme.mono).foregroundStyle(Theme.inkMute)
            if !node.current {
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(Theme.inkMute)
            }
        }
        .font(.subheadline)
        .padding(.leading, CGFloat(min(node.depth, 6)) * 14)
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
        .padding(.leading, CGFloat(min(node.depth, 6)) * 14 + 16)
    }
}

/// A titled block of text with an Edit button: the goal, the notes.
private struct TextCard: View {
    let title: String
    let text: String
    let identifier: String
    let edit: () -> Void

    var body: some View {
        ThemeCard(title: title) {
            Button("Edit", action: edit)
        } content: {
            Text(text).foregroundStyle(Theme.ink).textSelection(.enabled)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
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

    var body: some View {
        let fromAgent = message.role == .assistant
        VStack(alignment: fromAgent ? .leading : .trailing, spacing: 5) {
            Text(message.isToolTraffic ? "Tool" : (fromAgent ? "Agent" : "You"))
                .themeLabel(size: 10, color: Theme.inkMute)
                .padding(.horizontal, 4)
            Text(message.content)
                .font(message.isToolTraffic ? Theme.mono : .body)
                .foregroundStyle(message.isToolTraffic ? Theme.inkSoft : Theme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(bubble(fromAgent: fromAgent))
                .textSelection(.enabled)
        }
        // A reply from you sits to the right and stops short of the far edge, as in Messages.
        .padding(.leading, fromAgent ? 0 : 36)
        .frame(maxWidth: .infinity, alignment: fromAgent ? .leading : .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("detail.message.\(message.id)")
    }

    /// The agent's words on a card; yours on the accent's wash; tool traffic in a quiet well.
    @ViewBuilder
    private func bubble(fromAgent: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.largeRadius, style: .continuous)
        if message.isToolTraffic {
            shape.fill(Theme.well)
        } else if fromAgent {
            shape.fill(Theme.surface).overlay(shape.strokeBorder(Theme.rule, lineWidth: 1))
        } else {
            shape.fill(Theme.accent.opacity(0.14))
        }
    }
}
