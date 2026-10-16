import SwiftUI
import ZimmerKit

/// Live Mode and Live Voice — the app's side of `/live`. Opened from the session list's
/// waveform button. Each mode has one current conversation: Resume opens it, New starts a fresh
/// one (and ends the old). See docs/sessions/live.md.
struct LiveHomeView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var call = LiveCall.shared
    @State private var modes: [LiveModeAvailability] = []
    @State private var overview = LiveOverview(conversations: [], current: [:])
    @State private var path: [Int] = []
    @State private var error: String?
    @State private var starting: LiveMode?
    @State private var showingSettings = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let error {
                    Text(error).foregroundStyle(.red).accessibilityIdentifier("live.error")
                }
                ForEach(modes) { mode in
                    modeSection(mode)
                }
                if !overview.conversations.isEmpty {
                    Section("Recent conversations") {
                        ForEach(overview.conversations) { conversation in
                            NavigationLink(value: conversation.id) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(conversation.title).font(.subheadline).lineLimit(1)
                                    Text("\(conversation.mode.label) · \(conversation.status.rawValue.capitalized)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityIdentifier("live.recent.\(conversation.id)")
                        }
                    }
                }
            }
            .navigationTitle("Live")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("live.done")
                }
                ToolbarItem(placement: .primaryAction) {
                    LiveSettingsButton { showingSettings = true }
                }
            }
            .sheet(isPresented: $showingSettings) {
                NavigationStack { LiveSettingsView(api: model.api) }
            }
            .navigationDestination(for: Int.self) { id in
                LiveConversationView(id: id, api: model.api) { replacement in path = [replacement] }
            }
            .task { await load() }
            .refreshable { await load() }
            .onAppear {
                if let id = model.fixtureLiveConversation {
                    model.fixtureLiveConversation = nil
                    path = [id]
                }
            }
        }
    }

    @ViewBuilder
    private func modeSection(_ mode: LiveModeAvailability) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label(mode.label, systemImage: mode.mode == .voice ? "waveform" : "text.bubble")
                    .font(.headline)
                Text(mode.mode == .voice
                     ? "Talk to Zimmer. It answers out loud and hands real work to background sessions."
                     : "One continuous typed conversation that hands real work to Zimmer.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("\(mode.agentRoot) · \(mode.model)").font(.caption.monospaced()).foregroundStyle(.secondary)
                ForEach(mode.reasons, id: \.self) { reason in
                    Text(reason).font(.caption).foregroundStyle(.orange)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("live.mode.\(mode.mode.rawValue)")
            if let current = overview.current[mode.mode] {
                NavigationLink(value: current) {
                    Label(call.isActive(for: current) ? "Back to the call" : "Resume conversation", systemImage: "arrow.uturn.forward")
                }
                .accessibilityIdentifier("live.resume.\(mode.mode.rawValue)")
            }
            Button {
                Task { await start(mode.mode) }
            } label: {
                Label(starting == mode.mode ? "Starting…" : "New conversation", systemImage: "plus.circle")
            }
            .disabled(!mode.available || starting != nil)
            .accessibilityIdentifier("live.start.\(mode.mode.rawValue)")
        }
    }

    private func load() async {
        do {
            let api = model.api
            async let modes = api.liveModes()
            async let overview = api.liveConversations()
            self.modes = try await modes
            self.overview = try await overview
            error = nil
        } catch {
            self.error = (error as? ZimmerError)?.userMessage ?? "Couldn't reach Zimmer."
        }
    }

    private func start(_ mode: LiveMode) async {
        starting = mode
        defer { starting = nil }
        do {
            let conversation = try await model.api.startLiveConversation(mode)
            await load()
            path = [conversation.id]
        } catch {
            self.error = (error as? ZimmerError)?.userMessage ?? "Couldn't start the conversation."
        }
    }
}

/// One live conversation's thread: what was said or typed, each tool call collapsed to a line,
/// and the composer (Live Mode) or the call controls (Live Voice). Reads new turns every two
/// seconds while open, as the session page reads its conversation.
struct LiveConversationView: View {
    let id: Int
    let api: ZimmerAPI
    /// "New conversation" replaced this one with that id.
    var replaced: (Int) -> Void = { _ in }

    @ObservedObject private var call = LiveCall.shared
    @State private var conversation: LiveConversation?
    @State private var turns: [LiveTurn] = []
    @State private var draft = ""
    @State private var sending = false
    @State private var error: String?
    @State private var confirmingNew = false
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if let conversation { header(conversation) }
                        if turns.isEmpty, conversation != nil {
                            Text(conversation?.mode == .voice ? "Press Talk and say what you need." : "Say what you need. Anything slow becomes a background session.")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 24)
                        }
                        ForEach(turns) { turn in
                            LiveTurnRow(turn: turn).id(turn.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: turns.last?.id) { _, last in
                    if let last { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
                }
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal).accessibilityIdentifier("live.conversation.error")
            }
            if let conversation, conversation.status.isOpen {
                Divider()
                if conversation.mode == .voice { voiceControls(conversation) } else { composer(conversation) }
            }
        }
        .navigationTitle(conversation?.mode.label ?? "Live")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                LiveSettingsButton { showingSettings = true }
            }
            if let conversation {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button { confirmingNew = true } label: { Label("New conversation", systemImage: "plus.circle") }
                        if conversation.status.isOpen {
                            Button(role: .destructive) { Task { await finish() } } label: { Label("End conversation", systemImage: "stop.circle") }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityIdentifier("live.conversation.menu")
                }
            }
        }
        .confirmationDialog("End this conversation and start a new one?", isPresented: $confirmingNew, titleVisibility: .visible) {
            Button("New conversation") { Task { await startNew() } }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack { LiveSettingsView(api: api) }
        }
        .task(id: id) { await poll() }
        .onChange(of: call.activity) { _, _ in Task { await readNew() } }
    }

    private func header(_ conversation: LiveConversation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(conversation.title).font(.headline).lineLimit(1)
                Spacer()
                Text(conversation.status.rawValue.capitalized)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(conversation.status == .active ? Color.green.opacity(0.15) : Color.gray.opacity(0.15), in: Capsule())
                    .accessibilityIdentifier("live.status")
            }
            Text("\(conversation.agentRoot) · \(conversation.model)").font(.caption.monospaced()).foregroundStyle(.secondary)
            if !conversation.mcpServers.isEmpty {
                Text(conversation.mcpServers.joined(separator: " · ")).font(.caption.monospaced()).foregroundStyle(.indigo)
            }
            if conversation.status == .preparing {
                Text("Reading \(conversation.agentRoot)'s AGENTS.md…").font(.caption).foregroundStyle(.orange)
            }
            if let message = conversation.errorMessage, !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(conversation.status == .failed ? .red : .orange)
            }
            if conversation.responding {
                Text("Thinking…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func composer(_ conversation: LiveConversation) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message \(conversation.mode.label)…", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .accessibilityIdentifier("live.composer")
            Button {
                Task { await send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send")
            .accessibilityIdentifier("live.send")
        }
        .padding()
    }

    private func voiceControls(_ conversation: LiveConversation) -> some View {
        let mine = call.isActive(for: conversation.id)
        return VStack(spacing: 8) {
            if mine {
                Text(call.state.label).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("live.call.state")
            } else if let message = call.lastError, call.conversationID == conversation.id {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
            HStack(spacing: 16) {
                if mine {
                    Button { call.toggleMute() } label: {
                        Label(call.muted ? "Unmute" : "Mute", systemImage: call.muted ? "mic.slash" : "mic")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("live.mute")
                }
                Button {
                    if mine { call.hangUp() } else { Task { await call.start(conversation.id) } }
                } label: {
                    Label(mine ? "Hang up" : "Talk", systemImage: mine ? "phone.down.fill" : "waveform")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .tint(mine ? .red : .indigo)
                .accessibilityIdentifier("live.talk")
            }
            Text("Your phone talks to OpenAI directly; Zimmer runs the tools.").font(.caption2).foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - Loading

    private func poll() async {
        await readAll()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            await readNew()
        }
    }

    private func readAll() async {
        do {
            let fresh = try await api.liveConversation(id, afterTurn: nil)
            conversation = fresh
            turns = fresh.turns ?? []
            error = nil
        } catch {
            self.error = (error as? ZimmerError)?.userMessage ?? "Couldn't reach Zimmer."
        }
    }

    private func readNew() async {
        guard conversation != nil else { return await readAll() }
        do {
            let fresh = try await api.liveConversation(id, afterTurn: turns.last?.id ?? 0)
            conversation = fresh
            let known = Set(turns.map(\.id))
            turns += (fresh.turns ?? []).filter { !known.contains($0.id) }
            turns.sort { $0.id < $1.id }
            error = nil
        } catch {
            self.error = (error as? ZimmerError)?.userMessage ?? "Couldn't reach Zimmer."
        }
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        defer { sending = false }
        do {
            _ = try await api.sendLiveMessage(id, content: text)
            draft = ""
            await readNew()
        } catch {
            self.error = (error as? ZimmerError)?.userMessage ?? "Couldn't send that."
        }
    }

    private func finish() async {
        if call.isActive(for: id) { call.hangUp() }
        do {
            conversation = try await api.finishLiveConversation(id)
        } catch {
            self.error = (error as? ZimmerError)?.userMessage ?? "Couldn't end the conversation."
        }
    }

    private func startNew() async {
        guard let mode = conversation?.mode else { return }
        if call.isActive(for: id) { call.hangUp() }
        do {
            let fresh = try await api.startLiveConversation(mode)
            replaced(fresh.id)
        } catch {
            self.error = (error as? ZimmerError)?.userMessage ?? "Couldn't start a new conversation."
        }
    }
}

/// One turn: a bubble for what was said, a single line for a tool call (expandable to its output).
struct LiveTurnRow: View {
    let turn: LiveTurn
    @State private var expanded = false

    var body: some View {
        switch turn.role {
        case .tool:
            VStack(alignment: .leading, spacing: 4) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2)
                        Text(turn.toolLabel).font(.caption.monospaced())
                        if turn.toolError { Text("failed").font(.caption).foregroundStyle(.red) }
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                if expanded, let output = turn.toolOutput {
                    Text(output).font(.caption2.monospaced()).textSelection(.enabled).lineLimit(30)
                }
            }
            .padding(8)
            .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("live.turn.\(turn.id)")
        case .user, .assistant:
            let mine = turn.role == .user
            HStack {
                if mine { Spacer(minLength: 40) }
                VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                    Text(turn.content ?? "")
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .foregroundStyle(mine ? .white : .primary)
                        .background(mine ? Color.indigo : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                        .textSelection(.enabled)
                    if turn.source == "spoken" {
                        Text("spoken").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if !mine { Spacer(minLength: 40) }
            }
            .accessibilityIdentifier("live.turn.\(turn.id)")
        }
    }
}

/// The gear on the Live screens, which opens the Live settings.
struct LiveSettingsButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
        }
        .accessibilityLabel("Live settings")
        .accessibilityIdentifier("live-settings")
    }
}

/// The Live settings and the Live mode guidance — the app's side of `/live/settings`. One set for
/// the whole deployment: the models, voice, speaking speed and turn detection every live
/// conversation runs on, and the free text appended to the live model's instructions. Save sends
/// only the fields edited here, so a change the live agent made meanwhile is not undone; an open
/// Live Voice call is then brought up to what it can take mid-call. Opened from the gear on the
/// Live screens. See docs/sessions/live.md.
struct LiveSettingsView: View {
    let api: ZimmerAPI

    @Environment(\.dismiss) private var dismiss
    @State private var settings: LiveSettings?
    /// What was edited, by key, as text; "" puts the setting back to its default.
    @State private var edits: [String: String] = [:]
    @State private var guidance = ""
    @State private var error: String?
    @State private var notice: String?
    @State private var saving = false
    @State private var confirmingReset = false

    var body: some View {
        Form {
            if let error {
                Text(error).foregroundStyle(.red).accessibilityIdentifier("live-settings.error")
            }
            if let notice {
                Text(notice).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("live-settings.notice")
            }
            if let settings {
                fieldSection("Typed turns", path: "text", settings)
                fieldSection("Voice", path: "voice", settings)
                guidanceSection(settings)
                Section {
                    Button("Reset settings to defaults", role: .destructive) { confirmingReset = true }
                        .disabled(saving || settings.overrides.isEmpty)
                        .accessibilityIdentifier("live-settings.reset")
                } footer: {
                    Text("Puts every setting back to its default. The guidance is kept.")
                }
                historySection(settings)
            } else if error == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .accessibilityIdentifier("live-settings-view")
        .navigationTitle("Live settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }.accessibilityIdentifier("live-settings.done")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Saving…" : "Save") { Task { await save() } }
                    .disabled(saving || pendingChanges.isEmpty)
                    .accessibilityIdentifier("live-settings.save")
            }
        }
        .confirmationDialog("Put every Live setting back to its default?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset settings", role: .destructive) { Task { await reset() } }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: - Sections

    @ViewBuilder
    private func fieldSection(_ title: String, path: String, _ settings: LiveSettings) -> some View {
        let fields = settings.fields(on: path)
        if !fields.isEmpty {
            Section(title) {
                ForEach(fields) { field in
                    fieldRow(field, settings)
                }
            }
        }
    }

    private func fieldRow(_ field: LiveSettingField, _ settings: LiveSettings) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if field.type == .choice && !field.options.isEmpty {
                Picker(field.label, selection: binding(field, settings)) {
                    Text("Default (\(defaultText(field)))").tag("")
                    ForEach(field.options, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .accessibilityIdentifier("live-settings.field.\(field.key)")
            } else {
                HStack {
                    Text(field.label)
                    Spacer()
                    TextField("Default (\(defaultText(field)))", text: binding(field, settings))
                        .keyboardType(field.type == .integer ? .numberPad : .decimalPad)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("live-settings.field.\(field.key)")
                }
                HStack {
                    if let range = rangeText(field) {
                        Text(range).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Use default") { edits[field.key] = "" }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .disabled(binding(field, settings).wrappedValue.isEmpty)
                        .accessibilityIdentifier("live-settings.default.\(field.key)")
                }
            }
            if !field.help.isEmpty {
                Text(field.help).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func guidanceSection(_ settings: LiveSettings) -> some View {
        Section {
            TextEditor(text: $guidance)
                .frame(minHeight: 140)
                .font(.callout)
                .accessibilityIdentifier("live-settings.guidance")
            HStack {
                Text("\(guidance.count) / \(settings.guidanceMaxLength)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(guidance.count > settings.guidanceMaxLength ? Color.red : Color.secondary)
                    .accessibilityIdentifier("live-settings.guidance.count")
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = guidance }
                    .buttonStyle(.borderless)
                    .disabled(guidance.isEmpty)
                    .accessibilityIdentifier("live-settings.guidance.copy")
            }
        } header: {
            Text("Live mode guidance")
        } footer: {
            Text("Appended to the live model's instructions on every turn, typed and spoken; where it conflicts with the root's AGENTS.md, the guidance wins. The live agent can edit it too, and the history shows when it did.")
        }
    }

    @ViewBuilder
    private func historySection(_ settings: LiveSettings) -> some View {
        if !settings.history.isEmpty {
            Section("History") {
                ForEach(settings.history) { change in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Label(change.byAgent ? "Agent" : "Person", systemImage: change.byAgent ? "cpu" : "person.fill")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background((change.byAgent ? Color.orange : Color.indigo).opacity(0.15), in: Capsule())
                            Text(change.actor).font(.caption).lineLimit(1)
                            Spacer()
                            if let createdAt = change.createdAt {
                                Text(createdAt.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(change.keys, id: \.self) { key in
                            Text(describe(key, change.changes[key], settings)).font(.caption).foregroundStyle(.secondary)
                        }
                        if change.touchesGuidance {
                            Button("Restore guidance from before this edit") { Task { await restore(change) } }
                                .buttonStyle(.borderless)
                                .font(.caption)
                                .disabled(saving)
                                .accessibilityIdentifier("live-settings.restore.\(change.id)")
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Values

    /// A field's saved value as its editor shows it: "" when it is at its default.
    private func saved(_ field: LiveSettingField, in settings: LiveSettings) -> String {
        settings.isOverridden(field.key) ? settings.value(field.key).liveSettingText : ""
    }

    private func binding(_ field: LiveSettingField, _ settings: LiveSettings) -> Binding<String> {
        Binding(
            get: { edits[field.key] ?? saved(field, in: settings) },
            set: { edits[field.key] = $0 }
        )
    }

    private func defaultText(_ field: LiveSettingField) -> String {
        let text = field.defaultValue?.liveSettingText ?? ""
        return text.isEmpty ? "not set" : text
    }

    private func rangeText(_ field: LiveSettingField) -> String? {
        guard let low = field.min, let high = field.max else { return nil }
        return "\(JSONValue.number(low).liveSettingText)–\(JSONValue.number(high).liveSettingText)"
    }

    /// "Speaking speed: 1 → 0.8"; the guidance by name only.
    private func describe(_ key: String, _ diff: LiveSettingChange.Diff?, _ settings: LiveSettings) -> String {
        guard key != "guidance" else { return "Live mode guidance edited" }
        let label = settings.fields.first { $0.key == key }?.label ?? key
        let before = diff?.before?.liveSettingText ?? ""
        let after = diff?.after?.liveSettingText ?? ""
        return "\(label): \(before.isEmpty ? "not set" : before) → \(after.isEmpty ? "not set" : after)"
    }

    /// The edits that differ from what is saved: the `PATCH` body. Only these are sent.
    private var pendingChanges: [String: JSONValue] {
        guard let settings else { return [:] }
        var changes: [String: JSONValue] = [:]
        for field in settings.fields {
            guard let edited = edits[field.key] else { continue }
            var text = edited.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text != saved(field, in: settings) else { continue }
            if field.type != .choice {
                text = text.replacingOccurrences(of: ",", with: ".")
                if let number = Double(text) {
                    changes[field.key] = .number(number)
                    continue
                }
            }
            changes[field.key] = .string(text)
        }
        let trimmed = guidance.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != settings.guidance { changes["guidance"] = .string(trimmed) }
        return changes
    }

    // MARK: - Loading and writing

    private func load() async {
        do {
            show(try await api.liveSettings())
            error = nil
        } catch {
            self.error = (error as? ZimmerError)?.userMessage ?? "Couldn't reach Zimmer."
        }
    }

    private func show(_ fresh: LiveSettings) {
        settings = fresh
        edits = [:]
        guidance = fresh.guidance
    }

    private func save() async {
        let changes = pendingChanges
        guard !changes.isEmpty else { return }
        await write { try await api.updateLiveSettings(changes) }
    }

    private func reset() async {
        await write { try await api.resetLiveSettings() }
    }

    private func restore(_ change: LiveSettingChange) async {
        await write { try await api.restoreLiveGuidance(changeID: change.id) }
    }

    /// One write. The screen then shows what is saved, and an open Live Voice call is sent the
    /// `session.update` that brings it up to the new settings.
    private func write(_ request: () async throws -> LiveSettings) async {
        saving = true
        defer { saving = false }
        do {
            let fresh = try await request()
            show(fresh)
            error = nil
            notice = fresh.summary
            if fresh.changed ?? true { await LiveCall.shared.refreshSession() }
        } catch {
            self.error = (error as? ZimmerError)?.userMessage ?? "Couldn't save the Live settings."
        }
    }
}
