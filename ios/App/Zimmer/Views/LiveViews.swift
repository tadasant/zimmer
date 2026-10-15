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
