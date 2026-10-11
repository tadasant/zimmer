import SwiftUI
import ZimmerKit

/// One session's state, for the detail screen. Holds no rules of its own: what can be
/// followed up or archived is `SessionDetail`'s, what happens is the server's.
@MainActor
final class SessionDetailModel: ObservableObject {
    let id: Int
    private let api: ZimmerAPI
    /// Hands an error the whole app cares about (a sign-in that ended) to `AppModel`.
    var report: (ZimmerError) -> Void = { _ in }

    @Published private(set) var detail: SessionDetail?
    @Published private(set) var conversation: Conversation?
    @Published private(set) var isLoading = false
    @Published private(set) var isSending = false
    @Published var error: ZimmerError?
    @Published var notice: String?
    @Published var draft = ""

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
            error = nil
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: Error) {
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
            if now {
                result = try await api.sendNow(id, prompt: prompt)
            } else {
                result = try await api.followUp(id, prompt: prompt)
            }
            draft = ""
            notice = result.queued ? "Queued — it goes in when the current turn ends." : (now ? "Sent now." : "Sent.")
            error = nil
            Haptics.success()
            await load()
        } catch {
            fail(error)
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
    @State private var showingToolTraffic = false
    @State private var editing: EditedText?
    @State private var renaming = false
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
                        HierarchyCard(hierarchy: hierarchy)
                    }
                } else if model.isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
                if let error = model.error { ErrorBanner(error: error) }
                if let conversation = model.conversation {
                    conversationSection(conversation)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
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
        .overlay(alignment: .bottom) {
            // Above the composer, which is a bottom inset.
            Toast(text: $model.notice, identifier: "followup.notice")
        }
        .safeAreaInset(edge: .bottom) {
            if model.detail?.acceptsFollowUp ?? false { composer }
        }
        .refreshable { await model.load() }
        .task {
            model.report = { [weak app] error in app?.noteError(error) }
            await model.load()
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
                        .foregroundStyle(session.isFavorite ? Color.yellow : Color.accentColor)
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

    // MARK: - Header

    private func header(_ detail: SessionDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                StatusBadge(status: detail.session.status)
                    .accessibilityIdentifier("detail.status")
                if detail.session.isPriority {
                    Text("Priority")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .foregroundStyle(.red)
                        .background(Color.red.opacity(0.12), in: Capsule())
                }
                VisibilityLabel(session: detail.session)
                    .font(.caption)
                    .foregroundStyle(.indigo)
            }
            Text(detail.session.displayTitle)
                .font(.title2.weight(.bold))
                .accessibilityIdentifier("detail.title")
            metadataLine(detail.session)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Runtime, model, effort, root and age — the web UI's metadata block, on one line.
    private func metadataLine(_ session: SessionSummary) -> some View {
        var parts: [String] = []
        if let root = session.agentRoot { parts.append(root) }
        if let runtime = session.agentRuntime { parts.append(runtime) }
        if let model = session.model { parts.append(model) }
        if let effort = session.effort?.level { parts.append("effort \(effort)") }
        return HStack(spacing: 4) {
            Text(parts.joined(separator: " · "))
            if let date = session.updatedAt ?? session.createdAt {
                if !parts.isEmpty { Text("·") }
                Text(date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Conversation").font(.headline)
                Spacer()
                if conversation.messages.contains(where: \.isToolTraffic) {
                    Toggle("Tool calls", isOn: $showingToolTraffic)
                        .toggleStyle(.button)
                        .font(.caption)
                }
            }
            if conversation.truncated {
                Text("Showing the last \(conversation.messages.count) of \(conversation.total) messages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if conversation.messages.isEmpty {
                Text("No transcript yet.").foregroundStyle(.secondary)
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
                        Button(reply) { model.draft = reply }
                            .buttonStyle(.bordered)
                            .font(.footnote)
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(running ? "Queue Message" : "Send Message", text: $model.draft, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityIdentifier("followup.field")
                Button {
                    Task { await model.send() }
                } label: {
                    Image(systemName: model.isSending ? "hourglass" : (running ? "text.badge.plus" : "arrow.up.circle.fill"))
                        .font(.system(size: running ? 26 : 32))
                        .frame(width: 34, height: 34)
                }
                .disabled(model.isSending || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct SummaryCard: View {
    let status: StatusSummary
    let regenerate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Where things stand").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if status.generating == true {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Regenerate", action: regenerate)
                        .font(.caption)
                        .accessibilityIdentifier("detail.summary.regenerate")
                }
            }
            if let text = status.summary {
                Text(text)
            } else if status.generating == true {
                Text("Writing a status summary…").foregroundStyle(.secondary)
            }
            if let error = status.error, status.generating != true {
                Text("The last attempt failed: \(error)").font(.caption).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.summary")
    }
}

/// The web UI's hierarchy panel: who spawned this session and what it spawned, indented by
/// depth. Every other session in it opens on a tap.
private struct HierarchyCard: View {
    let hierarchy: SessionHierarchy

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hierarchy").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(hierarchy.nodes) { node in
                if node.current {
                    row(node).fontWeight(.semibold)
                } else {
                    NavigationLink(value: node.id) { row(node) }
                        .buttonStyle(.plain)
                }
            }
            if hierarchy.truncated {
                Text("Only part of the hierarchy is shown.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.hierarchy")
    }

    private func row(_ node: SessionHierarchy.Node) -> some View {
        HStack(spacing: 6) {
            StatusDot(status: node.status)
            Text(node.displayTitle).lineLimit(1)
            Spacer(minLength: 4)
            Text(verbatim: "#\(node.id)").font(.caption).foregroundStyle(.secondary)
            if !node.current {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .font(.subheadline)
        .padding(.leading, CGFloat(min(node.depth, 6)) * 14)
        .accessibilityIdentifier("hierarchy.node.\(node.id)")
    }
}

/// A titled block of text with an Edit button: the goal, the notes.
private struct TextCard: View {
    let title: String
    let text: String
    let identifier: String
    let edit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Edit", action: edit).font(.caption)
            }
            Text(text).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
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
                    Text(placeholder).foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5)
                }
                TextEditor(text: $text)
                    .focused($focused)
                    .accessibilityIdentifier("edit.text")
            }
            .padding()
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

private struct MessageBubble: View {
    let message: ConversationMessage

    var body: some View {
        let fromAgent = message.role == .assistant
        VStack(alignment: fromAgent ? .leading : .trailing, spacing: 4) {
            Text(message.isToolTraffic ? "Tool" : (fromAgent ? "Agent" : "You"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(message.content)
                .font(message.isToolTraffic ? .caption.monospaced() : .body)
                .padding(10)
                .background(
                    fromAgent ? Color(.secondarySystemGroupedBackground) : Color.accentColor.opacity(0.15),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: fromAgent ? .leading : .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("detail.message.\(message.id)")
    }
}
