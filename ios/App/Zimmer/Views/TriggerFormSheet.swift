import SwiftUI
import ZimmerKit

/// The web UI's trigger form (new and edit pages alike), as a sheet: the name, the conditions
/// (each card's fields by its type, with the Slack channel and WhatsApp chat pickers the web
/// form fetches), then the session template — agent root, the four catalog lists, goal,
/// session re-use, scheduling class, precedence, the burst cap, the coalescing window, skip
/// while pending, and the prompt template — in the web form's order and words. The server's
/// refusal is listed at the top, as the web form lists it. The two re-use switches under
/// session re-use are shown, not switched: they stay on the trigger's web page.
struct TriggerFormSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    /// The trigger being edited; nil for a new one.
    let editing: TriggerSummary?
    /// What the server saved. The sheet closes itself after calling this.
    let saved: (TriggerWrite) -> Void
    @State private var draft: TriggerDraft
    @State private var configs: AppConfigs?
    @State private var loadError: ZimmerError?
    @State private var refusal: TriggerValidationError?
    @State private var saveError: ZimmerError?
    @State private var saving = false
    @State private var channels: PickerLoad<SlackChannel> = .idle
    @State private var chats: PickerLoad<WhatsAppChat> = .idle
    @State private var goalIsCustom = false

    init(editing: TriggerSummary?, saved: @escaping (TriggerWrite) -> Void) {
        self.editing = editing
        self.saved = saved
        _draft = State(initialValue: editing.map(TriggerDraft.init(editing:)) ?? .blank())
    }

    var body: some View {
        NavigationStack {
            Form {
                refusalSection
                nameSection
                conditionsSections
                templateSections
            }
            .scrollDismissesKeyboard(.interactively)
            .themeGround()
            .navigationTitle(editing == nil ? "New Trigger" : "Edit Trigger")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : (editing == nil ? "Create" : "Update")) { Task { await save() } }
                        .disabled(saving)
                        .accessibilityIdentifier("trigger.form.save")
                }
            }
            .task { await loadConfigs() }
            .interactiveDismissDisabled(saving)
        }
        .tint(Theme.accent)
    }

    // MARK: - Sections

    @ViewBuilder
    private var refusalSection: some View {
        if let refusal {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label(refusal.headline, systemImage: "xmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.danger)
                    ForEach(Array(refusal.messages.enumerated()), id: \.offset) { _, message in
                        Text(verbatim: "• \(message)").font(.caption).foregroundStyle(Theme.ink)
                    }
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("trigger.form.error")
            }
            .themeRows()
        }
        if let error = saveError ?? loadError {
            Section { ErrorBanner(error: error).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
        }
    }

    private var nameSection: some View {
        Section {
            TextField("e.g., CI Failure Handler", text: $draft.name)
                .accessibilityIdentifier("trigger.form.name")
        } header: {
            required("Trigger Name")
        } footer: {
            Text("A descriptive name for this trigger")
        }
        .themeRows()
    }

    @ViewBuilder
    private var conditionsSections: some View {
        Section {
            Text("The trigger fires when **any** condition matches (OR logic). Add multiple conditions to respond to different events.")
                .font(.caption)
                .foregroundStyle(Theme.inkSoft)
            Button {
                draft.conditions.append(ConditionDraft(type: ""))
            } label: {
                Label("Add Condition", systemImage: "plus")
            }
            .accessibilityIdentifier("trigger.form.addCondition")
        } header: {
            required("Trigger Conditions")
        }
        .themeRows()
        ForEach($draft.conditions) { $condition in
            ConditionSection(
                index: draft.conditions.firstIndex(where: { $0.id == condition.id }) ?? 0,
                condition: $condition,
                channels: channels,
                chats: chats,
                loadChannels: { Task { await loadChannels() } },
                loadChats: { Task { await loadChats() } },
                remove: { remove(condition) }
            )
        }
    }

    @ViewBuilder
    private var templateSections: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                required("Agent Root")
                Picker("Agent Root", selection: $draft.agentRootName) {
                    Text("Select an agent root...").tag("")
                    ForEach(rootOptions, id: \.0) { option in Text(option.1).tag(option.0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityIdentifier("trigger.form.agentRoot")
                help("The codebase the agent will work with")
            }
            .onChange(of: draft.agentRootName) { _, name in
                // A root chosen here brings its own defaults, as the web form's root select
                // resets the four catalog lists and the goal.
                guard let option = configs?.agentRoots.first(where: { $0.name == name }) else { return }
                for kind in CatalogKind.allCases { draft.selections[kind] = kind.defaults(of: option) }
                draft.goal = option.defaultGoal ?? ""
                goalIsCustom = false
            }
            ForEach(CatalogKind.allCases) { kind in
                NavigationLink {
                    CatalogPicker(kind: kind, selection: Binding(get: { draft.selections[kind] ?? [] }, set: { draft.selections[kind] = $0 }))
                } label: {
                    LabeledContent(kind.label, value: summary(draft.selections[kind] ?? []))
                }
                .accessibilityIdentifier("trigger.form.catalog.\(kind.rawValue)")
            }
        } header: {
            Text("Session Template").themeLabel()
        } footer: {
            Text("Configure how sessions will be created when this trigger fires. MCP servers, skills, hooks and plugins come from the catalog; local skills with the same name take priority. An empty list means the trigger says nothing about that kind, so its sessions take the agent root's defaults.")
        }
        .themeRows()

        Section {
            Picker("Goal", selection: goalPreset) {
                Text("None").tag("")
                ForEach(configs?.goals ?? []) { goal in Text(goal.name ?? goal.id).tag(goal.id) }
                Text("Custom…").tag(Self.customGoal)
            }
            .accessibilityIdentifier("trigger.form.goalPreset")
            if goalIsCustom || (!draft.goal.isEmpty && !(configs?.goals ?? []).contains(where: { $0.id == draft.goal })) {
                TextField("Select a predefined goal or type your own...", text: $draft.goal, axis: .vertical)
                    .lineLimit(2...6)
                    .accessibilityIdentifier("trigger.form.goal")
            }
        } header: {
            Text("Goal").themeLabel()
        }
        .themeRows()

        Section {
            Toggle("Re-use existing session", isOn: $draft.reuseSession)
                .tint(Theme.accent)
                .accessibilityIdentifier("trigger.form.reuse")
            if draft.reuseSession {
                readOnlySwitch("Enqueue messages", on: editing?.enqueueMessages ?? false,
                               note: "When the session is still running, queue the new prompt as an enqueued message instead of skipping it.")
                    .accessibilityIdentifier("trigger.form.enqueue")
                readOnlySwitch("Resuscitate archived sessions", on: editing?.resuscitateArchived ?? false,
                               note: "When the previous session has been archived, automatically unarchive it and send the follow-up prompt instead of creating a new session.")
                    .accessibilityIdentifier("trigger.form.resuscitate")
            }
        } footer: {
            Text(reuseFooter)
        }
        .themeRows()

        Section {
            Picker("Scheduling class", selection: Binding(get: { draft.schedulingClass ?? "" }, set: { draft.schedulingClass = $0.isEmpty ? nil : $0 })) {
                Text(defaultClassLabel).tag("")
                Text("Priority — starts whenever it is ready").tag("priority")
                Text("Spot — waits for quota room or a free slot").tag("spot")
            }
            .accessibilityIdentifier("trigger.form.schedulingClass")
        } footer: {
            Text("Whether sessions this trigger spawns start straight away, or wait for headroom in the Claude Code quota windows. Priority always starts; spot waits when a window has reached its target, or every session slot is taken, under the limits set on the Inference page, and starts on its own later — it is never cancelled. Leave this on the default and the class follows the trigger's condition type: Slack triggers are priority, because someone is waiting on the answer; GitHub, scheduled and session-state triggers are spot. Changing this applies to sessions the trigger spawns from now on, and to its own already-spawned sessions still waiting to start. Saving tells you how many moved.")
        }
        .themeRows()

        Section {
            NumberField(title: "Precedence", placeholder: "None", value: $draft.precedence)
                .accessibilityIdentifier("trigger.form.precedence")
        } footer: {
            Text("Where the sessions this trigger spawns sit in the spot queue. Higher is worked first, on an absolute scale — 100000 comes before 50 — and nothing renumbers, so leave gaps to slot work in later. Leave blank to predefine nothing. It only orders spot sessions, but it is carried on every session the trigger spawns, so one later demoted to spot keeps the rank set here.")
        }
        .themeRows()

        Section {
            NumberField(title: "Max sessions per minute", placeholder: "No limit", value: $draft.maxSessionsPerMinute)
                .accessibilityIdentifier("trigger.form.maxSessionsPerMinute")
        } footer: {
            Text("Caps how many sessions this trigger may spawn in one minute. Leave blank for no limit. If more events than that arrive in a minute, the trigger spawns a single burst-notice session — linking the sessions it already spawned — and then spawns nothing until the burst ends (five quiet minutes). Events that arrive during the burst are dropped, and you get exactly one notice per burst.")
        }
        .themeRows()

        Section {
            NumberField(title: "Coalesce Slack messages within (seconds)", placeholder: "60", value: $draft.coalesceWindowSeconds)
                .accessibilityIdentifier("trigger.form.coalesceWindowSeconds")
            if !draft.hasSlackCondition {
                Text("This trigger has no Slack condition, so the window is not read on any of its fires.")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
            }
        } footer: {
            Text("Slack messages that land in the same channel, thread or DM within this many seconds of each other are treated as one event and spawn one session. Nothing is lost: the messages folded away are listed, with their links, in that session's prompt. Leave blank for the default (60s); set 0 to give every message its own session. Only Slack conditions coalesce.")
        }
        .themeRows()

        Section {
            Toggle("Skip while a session is still pending", isOn: $draft.skipIfPendingSession)
                .tint(Theme.accent)
                .accessibilityIdentifier("trigger.form.skipIfPendingSession")
        } footer: {
            Text("When enabled, this trigger creates nothing while a session it already spawned is still queued (waiting) or running — the fire is treated as already covered by that session. Sessions that are archived, failed, or waiting on you (needs input) do not block a fire. Use this for a trigger whose sessions all carry the same intent, so a slow one does not collect duplicate siblings. This bounds the backlog; \"Max sessions per minute\" above bounds the rate.")
        }
        .themeRows()

        Section {
            TextField("Enter the prompt template for triggered sessions.", text: $draft.promptTemplate, axis: .vertical)
                .lineLimit(6...16)
                .font(Theme.mono)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("trigger.form.prompt")
        } header: {
            required("Prompt Template")
        } footer: {
            Text("The prompt sent to the agent when the trigger fires. Variables: {{link}} (the Slack message, or the PR or issue URL), {{text}} (its content), {{author}}, {{channel}}, {{time}} (HH:MM), {{date}} (YYYY-MM-DD), {{event}} (Zimmer Event and GitHub conditions), {{repo}}, {{number}}, {{title}}, {{labels}} (GitHub), {{channel_id}}, {{message_ts}}, {{thread_ts}}, {{author_id}} (Slack, from Slack's own fields; empty unless in Slack's ID format). A GitHub condition whose template uses none of {{link}}, {{repo}} or {{number}} gets the PR or issue appended as a context block. Write any variable as {{text|untrusted}} to render it fenced off as outside input, with a note telling the agent it is data, not instructions; an email condition's template must write {{text}}, {{author}} and {{title}} that way.")
        }
        .themeRows()
    }

    // MARK: - Pieces

    private func required(_ title: String) -> Text {
        Text(title) + Text(" *").foregroundStyle(Theme.danger)
    }

    private func help(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(Theme.inkMute)
    }

    /// One of the two re-use switches, shown as stored: the web page switches them (#1318).
    private func readOnlySwitch(_ title: String, on: Bool, note: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            LabeledContent(title) { Text(on ? "On" : "Off").foregroundStyle(Theme.inkSoft) }
            help(note)
        }
        .accessibilityElement(children: .combine)
    }

    /// The roots the form can name: the catalog's, and a stored name it does not carry — marked,
    /// as the web form marks it — so the trigger can still be edited.
    private var rootOptions: [(String, String)] {
        var options = (configs?.invocableRoots ?? []).map { ($0.name, $0.title) }
        let stored = draft.agentRootName
        if !stored.isEmpty, !options.contains(where: { $0.0 == stored }) {
            options.append((stored, editing?.agentRootMissing == true ? "\(stored) (not in catalog)" : stored))
        }
        return options
    }

    private var reuseFooter: String {
        let words = "When enabled, subsequent trigger invocations will send a follow-up prompt to the previously created session instead of spawning a new one. If the previous session is no longer active, a new session will be created."
        return draft.reuseSession ? words + " Enqueue messages and Resuscitate archived are switched on the trigger's page in the browser." : words
    }

    private var defaultClassLabel: String {
        if let editing, editing.schedulingClass == nil, let effective = editing.effectiveSchedulingClass {
            return "Default (\(effective))"
        }
        return "Default for this trigger's conditions"
    }

    private static let customGoal = "\u{1}custom"

    /// The goal picker: a predefined goal's id, none, or custom text in the field below.
    private var goalPreset: Binding<String> {
        Binding(
            get: {
                if goalIsCustom { return Self.customGoal }
                if draft.goal.isEmpty { return "" }
                return (configs?.goals ?? []).contains(where: { $0.id == draft.goal }) ? draft.goal : Self.customGoal
            },
            set: { value in
                goalIsCustom = value == Self.customGoal
                draft.goal = value == Self.customGoal ? "" : value
            }
        )
    }

    private func summary(_ values: [String]) -> String {
        switch values.count {
        case 0: return "None"
        case 1: return values[0]
        default: return "\(values.count) chosen"
        }
    }

    /// A persisted condition is marked for the server to destroy; a drafted one just goes.
    private func remove(_ condition: ConditionDraft) {
        if let serverID = condition.serverID { draft.removedConditionIDs.append(serverID) }
        draft.conditions.removeAll { $0.id == condition.id }
    }

    // MARK: - Loading and saving

    private func loadConfigs() async {
        guard configs == nil else { return }
        do {
            configs = try await app.api.configs()
            loadError = nil
        } catch {
            loadError = error as? ZimmerError ?? .transport(error)
        }
    }

    /// Fetched once, the first time a Slack condition shows, and shared by every card.
    private func loadChannels() async {
        guard case .idle = channels else { return }
        channels = .loading
        do {
            channels = .loaded(try await app.api.triggerChannels())
        } catch {
            channels = .failed((error as? ZimmerError ?? .transport(error)).userMessage)
        }
    }

    private func loadChats() async {
        guard case .idle = chats else { return }
        chats = .loading
        do {
            chats = .loaded(try await app.api.whatsappChats())
        } catch {
            chats = .failed((error as? ZimmerError ?? .transport(error)).userMessage)
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        refusal = nil
        saveError = nil
        do {
            let written: TriggerWrite
            if let editing {
                written = try await app.api.updateTrigger(editing.id, draft)
            } else {
                written = try await app.api.createTrigger(draft)
            }
            Haptics.success()
            saved(written)
            dismiss()
        } catch let refused as TriggerValidationError {
            refusal = refused
            Haptics.failure()
        } catch {
            saveError = error as? ZimmerError ?? .transport(error)
            Haptics.failure()
        }
    }
}

/// One of the two lists the form fetches, as the web form tracks them: not asked for yet,
/// loading, here, or refused with the server's sentence.
enum PickerLoad<Item: Sendable>: Sendable {
    case idle, loading
    case loaded([Item])
    case failed(String)

    var items: [Item] {
        if case let .loaded(items) = self { return items }
        return []
    }
}

/// One condition card: its type, then the fields the web form shows for that type.
private struct ConditionSection: View {
    let index: Int
    @Binding var condition: ConditionDraft
    let channels: PickerLoad<SlackChannel>
    let chats: PickerLoad<WhatsAppChat>
    let loadChannels: () -> Void
    let loadChats: () -> Void
    let remove: () -> Void
    /// The web form's "Enter channel ID manually", which the form also opens itself when the
    /// list cannot be had.
    @State private var manualChannel = false

    private var prefix: String { "trigger.form.condition.\(index)" }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                required("Type")
                Picker("Type", selection: $condition.type) {
                    Text("Select condition type...").tag("")
                    ForEach(ConditionDraft.types, id: \.id) { type in Text(type.label).tag(type.id) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityIdentifier("\(prefix).type")
            }
            .onAppear { loadLists() }
            .onChange(of: condition.type) { _, _ in loadLists() }
            switch condition.type {
            case "slack": slackFields
            case "whatsapp": whatsappFields
            case "email": emailFields
            case "schedule": scheduleFields
            case "ao_event": eventFields(ConditionDraft.zimmerEvents, note: "Session events fire when an autonomous session transitions to the selected state; sessions created by this trigger are excluded to prevent loops. \"Account needs re-authentication\" is about a runtime account, not a session — it fires when one can no longer refresh its token, at most once every 12 hours per account.")
            case "system_event": eventFields(ConditionDraft.systemEvents, note: "Deployment-wide events, each fired once on the edge rather than on every check. \"Quota available again\" fires when the Claude Code account pool goes from serving nothing to serving something, and is what wakes quota-parked spot sessions. \"Fleet has room for more work\" fires when the deployment has been running fewer sessions than its configured ceiling for the whole of its configured stretch, with nothing parked on a quota outage and a pool that can serve. All three numbers are set on the Backlog top-up card on /inference.")
            case "github_label", "github_issue": githubFields
            default: EmptyView()
            }
            Button("Remove condition", role: .destructive, action: remove)
                .accessibilityIdentifier("\(prefix).remove")
        } header: {
            Text("Condition #\(index + 1)").themeLabel()
        }
        .themeRows()
    }

    private func loadLists() {
        if condition.type == "slack" { loadChannels() }
        if condition.type == "whatsapp" { loadChats() }
    }

    // MARK: Slack

    @ViewBuilder
    private var slackFields: some View {
        if condition.showsSlackChannel {
            VStack(alignment: .leading, spacing: 4) {
                required("Slack Channel")
                Picker("Slack Channel", selection: channelSelection) {
                    Text("— Select a channel —").tag("")
                    ForEach(channelOptions, id: \.0) { option in Text(option.1).tag(option.0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityIdentifier("\(prefix).channel")
                if let status = channelStatus {
                    Text(status.text).font(.caption).foregroundStyle(status.isError ? Theme.danger : Theme.inkMute)
                        .accessibilityIdentifier("\(prefix).channelStatus")
                }
                if manualChannel || channelsUnavailable {
                    TextField("Channel ID (e.g., C0A6BF8T45R)", text: manualChannelBinding)
                        .font(Theme.mono)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("\(prefix).channelID")
                    help("Enter the channel ID directly. Find it in the channel's details in Slack, or in the channel URL.")
                }
                Button("Enter channel ID manually") { manualChannel.toggle() }
                    .font(.caption)
                    .accessibilityIdentifier("\(prefix).channelManual")
                help("For \"Bot mention\" and the passive-listening types, leave the channel blank to monitor all channels the bot is in (plus DMs, for \"Bot mention\"). \"Direct message\" ignores the channel entirely — it watches DMs only.")
            }
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("Event Type")
            Picker("Event Type", selection: $condition.configuration.eventType) {
                ForEach(ConditionDraft.slackEventTypes, id: \.id) { type in Text(type.label).tag(type.id) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityIdentifier("\(prefix).eventType")
            help("Choose how this Slack condition fires. \"Bot mention\" and the passive-listening types only process messages from authorized users, and never fire on Zimmer's own or another app's messages. The two passive types are separate so a trigger can carry either or both — its conditions are ORed. \"Threads\" has no time limit; \"channels\" applies while Zimmer has posted at the top level of that channel within the last 6 hours.")
        }
        VStack(alignment: .leading, spacing: 4) {
            optional("Thread timestamp")
            TextField("e.g., 1767504875.131659", text: $condition.configuration.threadTS)
                .font(Theme.mono)
                .keyboardType(.numbersAndPunctuation)
                .accessibilityIdentifier("\(prefix).threadTS")
            help("For \"New message\" and \"Bot mention\", with a channel. Set this to a thread's parent timestamp to watch only that thread's replies: every new reply for \"New message\" — required for feeds that post as thread replies (e.g. a daily digest thread) — or only replies that @mention Zimmer for \"Bot mention\", which then ignores DMs and the rest of the channel. Leave blank to monitor the channel. Not supported for \"Direct message\" or the passive-listening types.")
        }
    }

    /// The fetched channels by name, as the web's select lists them, and a saved channel the
    /// list no longer carries kept so the trigger is not silently reset to blank.
    private var channelOptions: [(String, String)] {
        var options = channels.items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }.map { ($0.id, $0.label) }
        let stored = condition.configuration.channelID
        if !stored.isEmpty, !options.contains(where: { $0.0 == stored }) {
            let name = condition.configuration.channelName
            options.append((stored, "\(name.isEmpty ? stored : "#\(name)") (not in accessible list)"))
        }
        return options
    }

    /// Picking a channel writes its id and caches its name; the poller heals the name from the id.
    private var channelSelection: Binding<String> {
        Binding(
            get: { condition.configuration.channelID },
            set: { id in
                if let picked = channels.items.first(where: { $0.id == id }) {
                    condition.configuration.channelName = picked.name
                } else if id != condition.configuration.channelID {
                    condition.configuration.channelName = ""
                }
                condition.configuration.channelID = id
            }
        )
    }

    /// A hand-entered id clears the cached name, so the two cannot disagree.
    private var manualChannelBinding: Binding<String> {
        Binding(
            get: { condition.configuration.channelID },
            set: { text in
                condition.configuration.channelID = text.trimmingCharacters(in: .whitespaces)
                condition.configuration.channelName = ""
            }
        )
    }

    private var channelsUnavailable: Bool {
        switch channels {
        case .failed: return true
        case let .loaded(items): return items.isEmpty
        default: return false
        }
    }

    /// The web form's line under the channel select.
    private var channelStatus: (text: String, isError: Bool)? {
        switch channels {
        case .idle: return nil
        case .loading: return ("Loading channels…", false)
        case let .loaded(items):
            if items.isEmpty { return ("No channels found. The bot may not have been added to any channels yet — you can enter a channel ID manually.", true) }
            return ("\(items.count) channel\(items.count == 1 ? "" : "s") available.", false)
        case let .failed(message): return ("Couldn't load channels: \(message). Enter a channel ID manually.", true)
        }
    }

    // MARK: WhatsApp

    @ViewBuilder
    private var whatsappFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            required("Chat")
            Picker("Chat", selection: chatSelection) {
                Text("— Select a chat —").tag("")
                ForEach(chatOptions, id: \.0) { option in Text(option.1).tag(option.0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityIdentifier("\(prefix).chat")
            if let status = chatStatus {
                Text(status.text).font(.caption).foregroundStyle(status.isError ? Theme.danger : Theme.inkMute)
                    .accessibilityIdentifier("\(prefix).chatStatus")
            }
            TextField("Chat ID (e.g., 120363012345678901@g.us)", text: $condition.configuration.chatID)
                .font(Theme.mono)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("\(prefix).chatID")
            help("The chat the WhatsApp bridge's account is in. Pick it from the list, or paste its id. Groups end in @g.us.")
        }
        VStack(alignment: .leading, spacing: 4) {
            required("Fire on")
            Picker("Fire on", selection: $condition.configuration.mode) {
                ForEach(ConditionDraft.whatsappModes, id: \.id) { mode in Text(mode.label).tag(mode.id) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityIdentifier("\(prefix).mode")
            help("Messages that arrive within one poll (a minute) fire once, together. \"Listen\" hands every batch to the session, which decides whether to say anything. \"Addressed\" skips a batch unless one of its messages is for Zimmer, and still includes the rest of that batch as context.")
        }
        VStack(alignment: .leading, spacing: 4) {
            optional("Keywords", "(optional, for \"Addressed\")")
            LinesField(placeholder: "zimmer", lines: $condition.configuration.keywords)
                .accessibilityIdentifier("\(prefix).keywords")
            help("One per line. A message containing any of them, as a whole word, counts as addressing Zimmer. Blank means \"zimmer\".")
        }
        Toggle(isOn: $condition.configuration.includeFromMe) {
            Text("Also fire on messages the linked account sends from its own phone. Leave off for a dedicated Zimmer number. Turn on if the bridge is linked to your personal number and your own messages should count. Messages Zimmer posts through the bridge never fire.")
                .font(.caption)
                .foregroundStyle(Theme.inkSoft)
        }
        .tint(Theme.accent)
        .accessibilityIdentifier("\(prefix).includeFromMe")
    }

    private var chatOptions: [(String, String)] {
        var options = chats.items.map { ($0.id, $0.label) }
        let stored = condition.configuration.chatID
        if !stored.isEmpty, !options.contains(where: { $0.0 == stored }) {
            let name = condition.configuration.chatName
            options.insert((stored, name.isEmpty ? stored : name), at: 0)
        }
        return options
    }

    private var chatSelection: Binding<String> {
        Binding(
            get: { condition.configuration.chatID },
            set: { id in
                guard !id.isEmpty else { return }
                condition.configuration.chatID = id
                condition.configuration.chatName = chats.items.first(where: { $0.id == id })?.name ?? condition.configuration.chatName
            }
        )
    }

    private var chatStatus: (text: String, isError: Bool)? {
        switch chats {
        case .idle: return nil
        case .loading: return ("Loading chats…", false)
        case let .loaded(items): return items.isEmpty ? ("The WhatsApp account is in no chats yet. Paste a chat ID instead.", false) : nil
        case let .failed(message): return ("Could not load WhatsApp chats (\(message)). Paste the chat ID below.", true)
        }
    }

    // MARK: Email

    @ViewBuilder
    private var emailFields: some View {
        help("Fires one session per mail thread with new mail, about a minute after it arrives. The template must fence what the sender wrote: {{text|untrusted}}, {{author|untrusted}}, {{title|untrusted}}. {{message_id}} and {{thread_id}} are safe to write bare.")
        VStack(alignment: .leading, spacing: 4) {
            optional("Search")
            TextField("in:inbox", text: $condition.configuration.query)
                .font(Theme.mono)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("\(prefix).query")
            help("A Gmail search, ANDed with the poller's own terms. Blank means in:inbox. Narrow it with, say, to:zimmer+bugs@example.com or from:(a@example.com OR b@example.com). The mailbox is the one EMAIL_MCP_URL reads; its own mail never fires.")
        }
        Toggle(isOn: $condition.configuration.includeAutomated) {
            Text("Also fire on automated mail: Gmail's promotions, social, forums and updates categories, bounces, no-reply senders and auto-replies. Leave off unless the mailbox exists to receive notifications. An agent that answers an auto-reply is how two mailboxes end up writing to each other forever.")
                .font(.caption)
                .foregroundStyle(Theme.inkSoft)
        }
        .tint(Theme.accent)
        .accessibilityIdentifier("\(prefix).includeAutomated")
    }

    // MARK: Schedule

    @ViewBuilder
    private var scheduleFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            required("Schedule Mode")
            Picker("Schedule Mode", selection: $condition.scheduleMode) {
                Text("Recurring").tag(ConditionDraft.ScheduleMode.recurring)
                Text("One-time").tag(ConditionDraft.ScheduleMode.oneTime)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .accessibilityIdentifier("\(prefix).scheduleMode")
        }
        switch condition.scheduleMode {
        case .recurring:
            VStack(alignment: .leading, spacing: 4) {
                required("Frequency")
                HStack(spacing: 8) {
                    Text("Every").font(.subheadline.weight(.medium))
                    TextField("1", text: $condition.configuration.interval)
                        .keyboardType(.numberPad)
                        .frame(width: 56)
                        .multilineTextAlignment(.center)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("\(prefix).interval")
                    Picker("Unit", selection: $condition.configuration.unit) {
                        Text("select...").tag("")
                        ForEach(ConditionDraft.scheduleUnits, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("\(prefix).unit")
                }
            }
            if condition.showsDayOfWeek {
                VStack(alignment: .leading, spacing: 4) {
                    required("Day of Week")
                    Picker("Day of Week", selection: $condition.configuration.dayOfWeek) {
                        Text("Select day...").tag("")
                        ForEach(ConditionDraft.daysOfWeek, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("\(prefix).dayOfWeek")
                }
            }
            if condition.showsTime {
                VStack(alignment: .leading, spacing: 4) {
                    required("Time")
                    TextField("HH:MM", text: $condition.configuration.time)
                        .keyboardType(.numbersAndPunctuation)
                        .font(Theme.mono)
                        .accessibilityIdentifier("\(prefix).time")
                    help("24-hour, in the time zone below.")
                }
                timezonePicker
            }
        case .oneTime:
            VStack(alignment: .leading, spacing: 4) {
                required("Scheduled Date & Time")
                DatePicker("Scheduled Date & Time", selection: scheduledAt, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .accessibilityIdentifier("\(prefix).scheduledAt")
                help("The trigger fires once at this time, then auto-disables.")
            }
            .onAppear {
                // The web's field starts empty and is required; the picker always shows a time,
                // so what it shows is what is written.
                if condition.configuration.scheduledAt.isEmpty { condition.configuration.scheduledAt = Self.wallClock().string(from: Self.nextHour()) }
            }
            timezonePicker
        }
    }

    private var timezonePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Timezone")
            Picker("Timezone", selection: $condition.configuration.timezone) {
                ForEach(ScheduleTimeZone.options(including: condition.configuration.timezone)) { zone in
                    Text(zone.label()).tag(zone.name)
                }
            }
            .labelsHidden()
            .pickerStyle(.navigationLink)
            .accessibilityIdentifier("\(prefix).timezone")
        }
    }

    /// The HTML `datetime-local` value the server reads: a wall-clock time with no zone, which
    /// the condition's time zone then interprets.
    private static func wallClock() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter
    }

    private static func nextHour(from date: Date = Date()) -> Date {
        Calendar.current.dateInterval(of: .hour, for: date)?.end ?? date
    }

    private var scheduledAt: Binding<Date> {
        Binding(
            get: { Self.wallClock().date(from: String(condition.configuration.scheduledAt.prefix(16))) ?? Self.nextHour() },
            set: { condition.configuration.scheduledAt = Self.wallClock().string(from: $0) }
        )
    }

    // MARK: Zimmer and system events

    private func eventFields(_ events: [(id: String, label: String)], note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            required("Event")
            Picker("Event", selection: $condition.configuration.eventName) {
                Text("Select event...").tag("")
                ForEach(events, id: \.id) { event in Text(event.label).tag(event.id) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityIdentifier("\(prefix).eventName")
            help(note)
        }
    }

    // MARK: GitHub

    @ViewBuilder
    private var githubFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            required("Repositories")
            LinesField(placeholder: "owner/repo\nowner/another-repo", lines: $condition.configuration.repos)
                .accessibilityIdentifier("\(prefix).repos")
            help("One owner/name per line. All repos are checked in a single GitHub search request, so adding repos costs no extra API budget.")
        }
        if condition.type == "github_label" {
            VStack(alignment: .leading, spacing: 4) {
                required("Watch")
                Picker("Watch", selection: $condition.configuration.target) {
                    ForEach(ConditionDraft.githubTargets, id: \.id) { target in Text(target.label).tag(target.id) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityIdentifier("\(prefix).target")
            }
            VStack(alignment: .leading, spacing: 4) {
                required("Labels")
                LinesField(placeholder: "ready to merge", lines: $condition.configuration.labels)
                    .accessibilityIdentifier("\(prefix).labels")
                help("One label per line. The condition fires when any of them is added.")
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                optional("Exclude labels")
                LinesField(placeholder: "hold issue work gate", lines: $condition.configuration.excludeLabels)
                    .accessibilityIdentifier("\(prefix).excludeLabels")
                help("One label per line. An issue carrying any of them does not fire this condition. The label must be on the issue when it is created; a label added afterwards can lose the race with the next poll.")
            }
        }
        Text("Fires on the event, not the current state. An item that already carries the label (or already exists) when you save this condition is recorded as a baseline on the first poll and does not fire retroactively. Removing and re-adding a label fires again. Editing the repos or labels above re-baselines the condition.")
            .font(.caption)
            .foregroundStyle(Theme.accent)
    }

    // MARK: Labels

    private func required(_ title: String) -> Text {
        Text(title) + Text(" *").foregroundStyle(Theme.danger)
    }

    private func optional(_ title: String, _ note: String = "(optional)") -> Text {
        Text(title) + Text(" \(note)").foregroundStyle(Theme.inkMute)
    }

    private func help(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(Theme.inkMute)
    }
}

/// A list typed one entry per line, as the web's textareas take repos, labels and keywords.
/// The text is its own state so a newline survives being typed: the list is read from it,
/// never written back to it.
private struct LinesField: View {
    let placeholder: String
    @Binding var lines: [String]
    @State private var text: String

    init(placeholder: String, lines: Binding<[String]>) {
        self.placeholder = placeholder
        _lines = lines
        _text = State(initialValue: lines.wrappedValue.joined(separator: "\n"))
    }

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .lineLimit(2...8)
            .font(Theme.mono)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onChange(of: text) { _, text in
                lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
    }
}

/// An optional whole number, blank for none, as the web's number fields with a placeholder.
/// The text is its own state so a minus sign or a half-typed number is not thrown away.
private struct NumberField: View {
    let title: String
    let placeholder: String
    @Binding var value: Int?
    @State private var text: String

    init(title: String, placeholder: String, value: Binding<Int?>) {
        self.title = title
        self.placeholder = placeholder
        _value = value
        _text = State(initialValue: value.wrappedValue.map(String.init) ?? "")
    }

    var body: some View {
        LabeledContent(title) {
            TextField(placeholder, text: $text)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 120)
                .onChange(of: text) { _, text in
                    value = Int(text.trimmingCharacters(in: .whitespaces))
                }
        }
    }
}
