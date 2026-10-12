import SwiftUI
import ZimmerKit

/// Start work from a sentence. Zimmer's Quick Router reads the request, picks the agent
/// root and starts the session — the same flow as the web UI's bubble and the browser
/// extension, recorded as `ios_app`.
///
/// Three ways in, as the web UI has: the field pinned to the foot of the board
/// (`QuickRouterBar`, the web's "What do you want to do?" box), a button in the corner of
/// every other screen (`QuickRouterButton`, the web's bubble), and this sheet, which the
/// button opens. The sheet is the web bubble's panel: the words, photos and files, and under
/// *Advanced* the harness, the model and *Run as spot*. Opened from a session, the new one
/// threads under it.
struct QuickRouterView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var isStarting = false
    @State private var attachments: [MessageAttachment] = []
    @State private var notice: String?
    @State private var configs: AppConfigs?
    /// The harness and model pickers: "" is the blank option that names the default, so an
    /// untouched panel sends nothing and the server resolves it, as the web bubble's does.
    @State private var runtime = ""
    @State private var modelID = ""
    @State private var spot = false
    @State private var showingAdvanced = false
    @State private var threadUnderParent = true
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Say what you want done. Zimmer picks where it runs.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.inkSoft)
                    TextField("What do you want to do?", text: $prompt, axis: .vertical)
                        .lineLimit(4...10)
                        .foregroundStyle(Theme.ink)
                        .padding(14)
                        .themeCard(radius: Theme.smallRadius)
                        .focused($focused)
                        .accessibilityIdentifier("quickrouter.field")
                    if !attachments.isEmpty {
                        AttachmentChips(attachments: $attachments)
                    }
                    HStack(spacing: 8) {
                        AttachMenu { attach($0, unreadable: $1) }
                        Text("Photos, files")
                            .font(.caption)
                            .foregroundStyle(Theme.inkMute)
                        Spacer()
                    }
                    if let parent = app.quickRouterParent {
                        Toggle(isOn: $threadUnderParent) {
                            Text(verbatim: "Thread under #\(parent)")
                                .font(.subheadline)
                                .foregroundStyle(Theme.ink)
                        }
                        .tint(Theme.accent)
                        .accessibilityIdentifier("quickrouter.parent")
                    }
                    advanced
                    if let error = app.error { ErrorBanner(error: error) }
                }
                .padding()
            }
            .background(Theme.ground)
            .scrollDismissesKeyboard(.interactively)
            .overlay(alignment: .bottom) { Toast(text: $notice, identifier: "quickrouter.notice") }
            .navigationTitle("Quick Router")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isStarting ? "Starting…" : "Start") { Task { await start() } }
                        .disabled(isStarting || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("quickrouter.start")
                }
            }
            .onAppear {
                // Words typed in the board's bar come along when it opens the sheet.
                if prompt.isEmpty, !app.quickRouterDraft.isEmpty { prompt = app.quickRouterDraft }
                app.quickRouterDraft = ""
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-ZimmerFixtureQuickRouterAdvanced") { showingAdvanced = true }
                #endif
                focused = true
            }
            .task { configs = try? await app.api.configs() }
        }
    }

    /// The web bubble's Advanced accordion: harness, model, spot. Each picker leads with a
    /// blank option that names the default rather than preselecting it.
    private var advanced: some View {
        DisclosureGroup(isExpanded: $showingAdvanced) {
            VStack(alignment: .leading, spacing: 10) {
                if let configs {
                    let runtimes = configs.runtimeModels.keys.sorted()
                    // A menu picker shows only its value, so each carries its name beside it.
                    LabeledContent {
                        Picker("Harness", selection: $runtime) {
                            Text("Default (\(defaultRuntime(configs)))").tag("")
                            ForEach(runtimes, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .accessibilityIdentifier("quickrouter.runtime")
                    } label: {
                        Text("Harness").font(.subheadline).foregroundStyle(Theme.ink)
                    }
                    LabeledContent {
                        Picker("Model", selection: $modelID) {
                            Text("Default").tag("")
                            ForEach(configs.models(for: effectiveRuntime(configs))) { model in Text(model.title).tag(model.id) }
                        }
                        .labelsHidden()
                        .accessibilityIdentifier("quickrouter.model")
                    } label: {
                        Text("Model").font(.subheadline).foregroundStyle(Theme.ink)
                    }
                    .onChange(of: runtime) { _, runtime in
                        // A model of the harness just left is dropped, as the web panel drops it.
                        if !configs.models(for: runtime.isEmpty ? defaultRuntime(configs) : runtime).contains(where: { $0.id == modelID }) { modelID = "" }
                    }
                    Text("Leave both on Default and the router agent root's own harness and model apply. The models offered follow the harness.")
                        .font(.caption)
                        .foregroundStyle(Theme.inkSoft)
                } else {
                    LoadingState(text: "Loading the harnesses…").frame(height: 44)
                }
                Toggle(isOn: $spot) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Run as spot").font(.subheadline).foregroundStyle(Theme.ink)
                        Text("Waits for quota room instead of starting now, at the top of the spot queue.")
                            .font(.caption)
                            .foregroundStyle(Theme.inkSoft)
                    }
                }
                .tint(Theme.accent)
                .accessibilityIdentifier("quickrouter.spot")
            }
            .padding(.top, 8)
        } label: {
            Text("Advanced").themeLabel().accessibilityIdentifier("quickrouter.advanced")
        }
        .tint(Theme.inkMute)
        .padding(12)
        .themeCard(radius: Theme.smallRadius)
    }

    /// The harness a blank picker lands on: the default root's, or the first the server lists.
    private func defaultRuntime(_ configs: AppConfigs) -> String {
        configs.agentRoots.first(where: { $0.isDefault == true })?.defaultRuntime
            ?? configs.runtimeModels.keys.sorted().first
            ?? "claude_code"
    }

    private func effectiveRuntime(_ configs: AppConfigs) -> String {
        runtime.isEmpty ? defaultRuntime(configs) : runtime
    }

    /// Add what the pickers returned, refusing what the server would refuse — the whole
    /// request would fail on it — and saying what could not be read at all.
    private func attach(_ new: [MessageAttachment], unreadable: [String]) {
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

    private func start() async {
        isStarting = true
        defer { isStarting = false }
        // The server validates a model against the harness it was picked for. The app
        // cannot know which root the router is (configs does not say), so a model always
        // travels with the harness the picker listed it under.
        let pickedRuntime = runtime.isEmpty ? nil : runtime
        let request = QuickRouterRequest(
            prompt: prompt,
            runtime: modelID.isEmpty ? pickedRuntime : configs.map(effectiveRuntime) ?? pickedRuntime,
            model: modelID.isEmpty ? nil : modelID,
            spot: spot,
            parentSessionID: threadUnderParent ? app.quickRouterParent : nil,
            attachments: attachments
        )
        _ = await app.startQuickRouter(request)
    }
}

/// The web UI's prompt box on the board, pinned to the foot of the Sessions screen: the
/// first thing a thumb reaches, and the most prominent thing on the main screen. Type a
/// sentence, send it, and the session it starts opens. The sparkles open the sheet with
/// the words so far, for photos, files and the Advanced choices.
///
/// It stands aside while the search box has the keyboard — a second field above the
/// keyboard would take the room the results need — and while rows are being selected,
/// when the Trash bar has the foot.
struct QuickRouterBar: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.isSearching) private var isSearching
    var editing = false
    @State private var prompt = ""
    @State private var isStarting = false
    @FocusState private var focused: Bool

    var body: some View {
        if !isSearching && !editing { bar }
    }

    private var bar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Button {
                    app.quickRouterParent = nil
                    app.quickRouterDraft = prompt
                    app.showingQuickRouter = true
                } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.top, 2)
                }
                .accessibilityLabel("More options")
                .accessibilityIdentifier("quickrouter.bar.more")
                TextField("What do you want to do?", text: $prompt, axis: .vertical)
                    .lineLimit(1...5)
                    .foregroundStyle(Theme.ink)
                    .focused($focused)
                    .accessibilityIdentifier("quickrouter.bar.field")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(focused ? Theme.accent.opacity(0.7) : Theme.rule, lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.15), value: focused)
            Button {
                Task { await start() }
            } label: {
                Image(systemName: isStarting ? "hourglass" : "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(canSend ? Color.white : Theme.inkMute)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(canSend ? Theme.accentFill : Theme.well))
                    .overlay(Circle().strokeBorder(Theme.gold.opacity(canSend ? 0.9 : 0), lineWidth: 1.5))
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.snappy(duration: 0.2), value: canSend)
            }
            .disabled(!canSend)
            .accessibilityLabel("Start")
            .accessibilityIdentifier("quickrouter.bar.start")
        }
        .padding(.horizontal, Theme.margin)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background {
            Theme.ground
                .overlay(alignment: .top) { Theme.rule.frame(height: 1) }
                .ignoresSafeArea(edges: .bottom)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quickrouter.bar")
    }

    private var canSend: Bool {
        !isStarting && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func start() async {
        isStarting = true
        defer { isStarting = false }
        if await app.startQuickRouter(prompt) {
            prompt = ""
            focused = false
        }
    }
}

/// The web UI's bubble: the Quick Router in the bottom-right corner of every screen that is
/// not the board (the board has the bar). Indigo, with the mark's gold ring. The one shadow
/// in the app, because a button floating over content needs the lift; Motet's play button
/// is the precedent. On a session, `parent` is that session, so the new one threads under it.
struct QuickRouterButton: View {
    @EnvironmentObject private var app: AppModel
    var parent: Int?

    var body: some View {
        Button {
            app.quickRouterParent = parent
            app.showingQuickRouter = true
        } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(Circle().fill(Theme.accentFill))
                .overlay(Circle().strokeBorder(Theme.gold.opacity(0.9), lineWidth: 1.5))
                .shadow(color: Theme.navy.opacity(0.28), radius: 10, y: 5)
        }
        .accessibilityLabel("Quick Router")
        .accessibilityIdentifier("quickrouter.fab")
    }
}

extension View {
    /// The Quick Router button in the corner, above whatever the screen keeps at its foot
    /// (a composer, a tab bar) — apply it before a `safeAreaInset` so it sits above the inset.
    /// `parent` is the session the screen shows, when it shows one.
    func quickRouterCorner(parent: Int? = nil) -> some View {
        // The scroll content keeps room at its foot, so the last row or message can be
        // scrolled clear of the button rather than living under it.
        contentMargins(.bottom, 76, for: .scrollContent)
            .overlay(alignment: .bottomTrailing) {
                QuickRouterButton(parent: parent)
                    .padding(.trailing, Theme.margin)
                    .padding(.bottom, 14)
            }
    }
}
