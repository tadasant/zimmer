import SwiftUI
import ZimmerKit

/// Start work from a sentence. Zimmer's Quick Router reads the request, picks the agent
/// root and starts the session — the same flow as the web UI's bubble and the browser
/// extension, recorded as `ios_app`.
///
/// Three ways in, as the web UI has: the field pinned to the foot of the board
/// (`QuickRouterBar`, the web's "What do you want to do?" box), a button in the corner of
/// every other screen (`QuickRouterButton`, the web's bubble), and this sheet, which the
/// button and the bar's sparkles open. The sheet is the web bubble's panel: the words, photos
/// and files, and under *Advanced* the harness, the model and *Run as spot*. Opened from a
/// session, the new one threads under it, and that session's page goes with the words as the
/// bubble sends the page it was typed on. *Open the session when it starts* off is the
/// bubble's plain *Submit*: the session starts and this screen stays.
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
    /// The web bubble's *Submit & Open* (on) or *Submit* (off).
    @State private var opensSession = true
    /// The board's bar opened this sheet: the words go back to the bar when it closes, emptied
    /// by a start. Held here, not read off `AppModel`, so another opening cannot change it.
    @State private var openedFromBar = false
    /// A start succeeded. The sheet's `onDisappear` can run before or after `start()` returns,
    /// so this, not `isStarting` alone, is what keeps it from handing the words back.
    @State private var started = false
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
                        AttachMenu { attach($0, problems: $1) }
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
                    if let page = app.quickRouterPage {
                        // The web bubble's "Page context is automatically included."
                        Label {
                            Text("Page context is included: \(page.title)")
                        } icon: {
                            Image(systemName: "doc.text")
                        }
                        .font(.caption)
                        .foregroundStyle(Theme.inkMute)
                        .lineLimit(2)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("quickrouter.page")
                    }
                    Toggle(isOn: $opensSession) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Open the session when it starts").font(.subheadline).foregroundStyle(Theme.ink)
                            Text("Off, it starts in the background and this screen stays.")
                                .font(.caption)
                                .foregroundStyle(Theme.inkSoft)
                        }
                    }
                    .tint(Theme.accent)
                    .accessibilityIdentifier("quickrouter.open")
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
                // Not while a start is in flight: the session it starts would open with the words
                // it started from still in the bar.
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isStarting) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isStarting ? "Starting…" : "Start") { Task { await start() } }
                        .disabled(isStarting || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("quickrouter.start")
                }
            }
            .onAppear {
                // Words typed in the board's bar come along when it opens the sheet.
                if let draft = app.quickRouterDraft {
                    openedFromBar = true
                    if prompt.isEmpty { prompt = draft }
                    app.quickRouterDraft = nil
                }
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-ZimmerFixtureQuickRouterAdvanced") { showingAdvanced = true }
                #endif
                focused = true
            }
            .onDisappear {
                // Closed without starting: the bar gets the words as the sheet left them. After a
                // start, `start()` empties the bar instead.
                if openedFromBar, !isStarting, !started { app.quickRouterBarHandback = prompt }
            }
            .interactiveDismissDisabled(isStarting)
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
    private func attach(_ new: [MessageAttachment], problems: [String]) {
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

    private func start() async {
        isStarting = true
        defer { isStarting = false }
        // Before the await, and whatever it returns: a start closes the sheet and may push the
        // session, and the keyboard must not outlive either.
        focused = false
        dismissKeyboard()
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
            attachments: attachments,
            // The screen, not the thread: it goes whether or not the start threads under the session.
            page: app.quickRouterPage
        )
        // Read before the await: a start closes the sheet before it returns.
        let fromBar = openedFromBar
        guard await app.startQuickRouter(request, open: opensSession) else { return }
        started = true
        if fromBar { app.quickRouterBarHandback = "" }
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
                    // Let go of the keyboard first: UIKit hands first responder back to the
                    // field that had it when a sheet closes, so a bar still focused here would
                    // take the keyboard again as the sheet's start closes it.
                    focused = false
                    dismissKeyboard()
                    app.openQuickRouter(draft: prompt)
                } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.top, 2)
                }
                .disabled(isStarting)
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
        // The sheet this bar opened has closed: nothing after a start, so the words typed
        // before the sheet opened do not outlive the session they started; the sheet's words
        // after a Cancel. Read on appear too, for a hand-back made while the bar stood aside.
        .onChange(of: app.quickRouterBarHandback) { _, _ in takeHandback() }
        .onAppear { takeHandback() }
    }

    private func takeHandback() {
        guard let words = app.quickRouterBarHandback else { return }
        prompt = words
        app.quickRouterBarHandback = nil
    }

    private var canSend: Bool {
        !isStarting && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The keyboard goes as the words are sent, not after the answer: by the time the start
    /// returns, the session's page is pushed over the board and the bar is off screen, and a
    /// failed start keeps its words in the bar for another try without holding the keyboard.
    private func start() async {
        isStarting = true
        defer { isStarting = false }
        focused = false
        dismissKeyboard()
        if await app.startQuickRouter(prompt) { prompt = "" }
    }
}

/// The web UI's bubble: the Quick Router in the bottom-right corner of every screen that is
/// not the board (the board has the bar). Indigo, with the mark's gold ring. The one shadow
/// in the app, because a button floating over content needs the lift; Motet's play button
/// is the precedent. On a session, `parent` is that session, so the new one threads under it,
/// and `page` is its page, sent as the bubble sends the page it was typed on.
struct QuickRouterButton: View {
    @EnvironmentObject private var app: AppModel
    var parent: Int?
    var page: QuickRouterPage?

    var body: some View {
        Button {
            app.openQuickRouter(parent: parent, page: page)
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

/// Resign whatever holds the keyboard. Clearing a `@FocusState` covers the field SwiftUI
/// knows is focused; this covers the one UIKit made first responder behind its back, as it
/// does when a sheet closes and hands focus back to the field that had it.
@MainActor
func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

extension View {
    /// The Quick Router button in the corner, above whatever the screen keeps at its foot
    /// (a composer, a tab bar) — apply it before a `safeAreaInset` so it sits above the inset.
    /// `parent` is the session the screen shows, when it shows one, and `page` its page.
    func quickRouterCorner(parent: Int? = nil, page: QuickRouterPage? = nil) -> some View {
        // The scroll content keeps room at its foot, so the last row or message can be
        // scrolled clear of the button rather than living under it.
        contentMargins(.bottom, 76, for: .scrollContent)
            .overlay(alignment: .bottomTrailing) {
                QuickRouterButton(parent: parent, page: page)
                    .padding(.trailing, Theme.margin)
                    .padding(.bottom, 14)
            }
    }
}
