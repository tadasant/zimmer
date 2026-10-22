import SwiftUI
import ZimmerKit

/// The web UI's trigger page: its status and the labels beside its name, why it failed if it
/// did, when it last fired and the session it last started, what fires it, the root and every
/// setting its sessions get (re-use, pending, coalescing, missed fires, burst cap, scheduling
/// class, precedence, the catalog artifacts), its goal and prompt, and the sessions it made.
/// Turn it on or off (or re-arm it), run it now, filling the template's variables as the web
/// page's Run Now panel does, edit it in the web form's sheet, or delete it after the web
/// page's confirmation. Its two re-use switches stay in the browser.
struct TriggerDetailView: View {
    let id: Int
    @EnvironmentObject private var app: AppModel
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State private var detail: TriggerDetail?
    @State private var error: ZimmerError?
    @State private var notice: String?
    @State private var confirmingInvoke = false
    /// The edit form.
    @State private var editing = false
    @State private var confirmingDelete = false
    /// A delete in flight: the page goes when the server has answered.
    @State private var deleting = false
    /// The Run Now sheet, for a template with variables to fill.
    @State private var runningWithVariables = false
    /// A toggle in flight: a second tap waits for the first.
    @State private var toggling = false

    var body: some View {
        List {
            if let error { ErrorBanner(error: error).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
            if let detail { content(detail.trigger, recent: detail.recentSessions) }
        }
        .themeGround()
        .overlay { if detail == nil && error == nil { LoadingState() } }
        .overlay(alignment: .bottom) { Toast(text: $notice) }
        .confirmationDialog(
            "Invoke now?",
            isPresented: $confirmingInvoke,
            titleVisibility: .visible,
            presenting: detail?.trigger
        ) { trigger in
            Button("Invoke \(trigger.name)") { Task { await invoke() } }
                .accessibilityIdentifier("trigger.invoke.confirm")
        } message: { _ in
            Text("It fires as if its condition had matched, as the web UI's Invoke does.")
        }
        .sheet(isPresented: $runningWithVariables) {
            if let trigger = detail?.trigger {
                TriggerRunSheet(trigger: trigger) { variables in await invoke(variables: variables) }
            }
        }
        .sheet(isPresented: $editing) {
            if let trigger = detail?.trigger {
                TriggerFormSheet(editing: trigger) { written in
                    detail?.trigger = written.trigger
                    notice = written.notice ?? "Saved"
                    Task { await load() }
                }
            }
        }
        // The web page's `turbo_confirm`, word for word.
        .confirmationDialog(
            "Are you sure you want to delete this trigger?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { Task { await delete() } }
        }
        .refreshable { await load() }
        .task { await load() }
        .navigationTitle(detail?.trigger.name ?? "Trigger")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { actions }
        }
    }

    @ViewBuilder
    private func content(_ trigger: TriggerSummary, recent: [TriggerDetail.RecentSession]) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                FlowLayout(spacing: 6, rowSpacing: 6) {
                    TriggerStatusBadge(status: trigger.status)
                    ForEach(trigger.badges, id: \.self) { badge in
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .foregroundStyle(Theme.inkSoft)
                            .background(Theme.well, in: Capsule())
                    }
                }
                .accessibilityIdentifier("trigger.detail.badges")
                Toggle(isOn: Binding(get: { trigger.isEnabled }, set: { _ in Task { await toggle() } })) {
                    Text(trigger.isFailed ? "Re-arm" : "Enabled").font(.subheadline).foregroundStyle(Theme.ink)
                }
                .tint(Theme.accent)
                .disabled(toggling)
                .accessibilityIdentifier("trigger.detail.toggle")
            }
            .padding(.vertical, 2)
        }
        .themeRows()

        if trigger.isFailed {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(failedHeadline(trigger)).font(.subheadline.weight(.medium)).foregroundStyle(Theme.danger)
                    // Whether re-arming fires it again depends on whether a one-time wake was
                    // already spent, which the API does not say; the web page does.
                    Text("It will not retry on its own. The trigger's page in the browser says whether re-arming fires it again.")
                        .font(.caption)
                        .foregroundStyle(Theme.inkSoft)
                    if let lastError = trigger.lastError {
                        Text(lastError)
                            .font(Theme.mono)
                            .foregroundStyle(Theme.ink)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 2)
                .accessibilityIdentifier("trigger.detail.failure")
            }
            .themeRows()
        }

        Section {
            row("Sessions created") { Text(verbatim: "\(trigger.sessionsCreated ?? 0)").monospacedDigit() }
            row("Last fired") {
                if let last = trigger.lastTriggeredAt {
                    Text(last, format: .relative(presentation: .named))
                } else {
                    Text("Never")
                }
            }
            if let session = trigger.lastSessionID {
                Button {
                    app.path = [session]
                } label: {
                    row("Last session") {
                        HStack(spacing: 4) {
                            Text(verbatim: "#\(session)").font(Theme.mono)
                            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(Theme.inkMute)
                        }
                    }
                }
                .accessibilityIdentifier("trigger.detail.lastSession")
            }
        } header: {
            Text("Activity").themeLabel()
        }
        .themeRows()

        if !trigger.conditions.isEmpty {
            Section {
                ForEach(Array(trigger.conditions.enumerated()), id: \.offset) { _, condition in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(condition.label).themeLabel(size: 10, color: Theme.accent)
                        if !condition.detail.isEmpty {
                            Text(verbatim: condition.detail)
                                .font(.subheadline)
                                .foregroundStyle(Theme.ink)
                        }
                        if let last = condition.lastTriggeredAt {
                            let age = Format.age(last)
                            Text(verbatim: age == "now" ? "fired just now" : "fired \(age)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Theme.inkMute)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                // The web page's "(OR logic)": any one of them fires it.
                Text("Fires on any of").themeLabel()
            }
            .themeRows()
        }

        Section {
            if let root = trigger.agentRoot {
                VStack(alignment: .leading, spacing: 3) {
                    row("Agent root") {
                        Text(root).font(Theme.mono).foregroundStyle(trigger.agentRootMissing ? Theme.danger : Theme.ink)
                    }
                    if trigger.agentRootMissing {
                        Text("Not in this deployment's catalog. Every fire that has to start a session fails until the name resolves.")
                            .font(.caption)
                            .foregroundStyle(Theme.danger)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("trigger.detail.agentRoot")
            }
            row("Session re-use") { onOff(trigger.reuseSession) }
            reuseOption("Enqueue messages", on: trigger.enqueueMessages, reuse: trigger.reuseSession)
                .accessibilityIdentifier("trigger.detail.enqueue")
            reuseOption("Resuscitate archived", on: trigger.resuscitateArchived, reuse: trigger.reuseSession)
                .accessibilityIdentifier("trigger.detail.resuscitate")
            VStack(alignment: .leading, spacing: 3) {
                row("Skip while pending") { onOff(trigger.skipIfPendingSession) }
                if trigger.skipIfPendingSessionInert {
                    Text("Inert while this trigger has a live session to re-use — those fires never reach the spawn path this setting guards. It applies again on a fire that has to spawn.")
                        .font(.caption).foregroundStyle(Theme.inkMute)
                } else if trigger.skipIfPendingSession {
                    Text("A fire spawns nothing while a session it started is still pending.").font(.caption).foregroundStyle(Theme.inkMute)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("trigger.detail.skipPending")
            VStack(alignment: .leading, spacing: 3) {
                row("Coalescing window") {
                    HStack(spacing: 4) {
                        if let seconds = trigger.effectiveCoalesceWindowSeconds, seconds > 0 {
                            Text(verbatim: "\(seconds)s").monospacedDigit()
                        } else {
                            Text("Off")
                        }
                        if trigger.coalesceWindowSeconds == nil { Text("(default)").foregroundStyle(Theme.inkMute) }
                    }
                }
                Text(coalescingNote(trigger)).font(.caption).foregroundStyle(Theme.inkMute)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("trigger.detail.coalescing")
            if trigger.missedFireCount > 0 {
                VStack(alignment: .leading, spacing: 3) {
                    row("Missed fires") {
                        Text(verbatim: "\(trigger.missedFireCount) consecutive fire\(trigger.missedFireCount == 1 ? "" : "s") coalesced"
                             + (trigger.firstMissedFireAt.map { " since \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""))
                            .foregroundStyle(Theme.danger)
                            .multilineTextAlignment(.trailing)
                    }
                    Text("The re-used session is still holding an undelivered prompt, so the scheduled work has not run. It resumes on its own once that session takes a turn.")
                        .font(.caption).foregroundStyle(Theme.inkMute)
                }
                .accessibilityElement(children: .contain)
            .accessibilityIdentifier("trigger.detail.missedFires")
            }
            row("Max sessions / minute") {
                HStack(spacing: 6) {
                    if let max = trigger.maxSessionsPerMinute { Text(verbatim: "\(max)").monospacedDigit() } else { Text("No limit") }
                    if trigger.bursting { Text("Bursting — spawns suppressed").font(.caption).foregroundStyle(Theme.danger) }
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                row("Scheduling class") {
                    HStack(spacing: 6) {
                        Text(trigger.effectiveSchedulingClass ?? "default")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 2.5)
                            .foregroundStyle(trigger.effectiveSchedulingClass == "priority" ? Theme.accent : Theme.inkSoft)
                            .background((trigger.effectiveSchedulingClass == "priority" ? Theme.accent : Theme.inkSoft).opacity(0.14), in: Capsule())
                        Text(trigger.schedulingClass == nil ? "default for its conditions" : "set on this trigger").font(.caption).foregroundStyle(Theme.inkMute)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("trigger.detail.schedulingClass")
            row("Precedence") {
                if let precedence = trigger.precedence {
                    HStack(spacing: 6) {
                        Text(verbatim: "\(precedence)").monospacedDigit()
                        Text("stamped on the sessions it spawns — higher is worked first").font(.caption).foregroundStyle(Theme.inkMute)
                    }
                } else {
                    Text("none predefined").foregroundStyle(Theme.inkMute)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("trigger.detail.precedence")
            chips("MCP servers", trigger.mcpServers, list: "mcp_servers", trigger: trigger, tone: Theme.accent)
            chips("Skills", trigger.catalogSkills, list: "catalog_skills", trigger: trigger, tone: Theme.success)
            chips("Hooks", trigger.catalogHooks, list: "catalog_hooks", trigger: trigger, tone: Theme.warning)
            chips("Plugins", trigger.catalogPlugins, list: "catalog_plugins", trigger: trigger, tone: Theme.snooze)
            if let goal = trigger.goal, !goal.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Goal").font(.subheadline).foregroundStyle(Theme.inkSoft)
                    Text(goal).font(.subheadline).foregroundStyle(Theme.ink)
                }
            }
        } header: {
            Text("Sessions it starts").themeLabel()
        } footer: {
            Text("Enqueue messages and Resuscitate archived are switched on the trigger's page in the browser, with the rest of its settings. An empty artifact list means the trigger says nothing about that kind, so its sessions take the agent root's defaults.")
                .font(.caption)
                .foregroundStyle(Theme.inkMute)
        }
        .themeRows()

        if let template = trigger.promptTemplate, !template.isEmpty {
            Section {
                Text(template)
                    .font(Theme.mono)
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .padding(.vertical, 2)
                    .accessibilityIdentifier("trigger.detail.prompt")
            } header: {
                Text("Prompt template").themeLabel()
            } footer: {
                Text("Sent to the agent when the trigger fires. Variables: {{link}}, {{text}}, {{author}}, {{channel}}, {{time}}, {{date}}, {{event}}" +
                     (trigger.promptVariables.isEmpty ? "." : "; Run Now asks for \(trigger.promptVariables.map { "{{\($0)}}" }.joined(separator: ", "))."))
                    .font(.caption)
                    .foregroundStyle(Theme.inkMute)
            }
            .themeRows()
        }

        Section {
            if recent.isEmpty {
                Text("None yet. They show up here when it fires.").font(.subheadline).foregroundStyle(Theme.inkSoft)
            }
            ForEach(recent) { session in
                Button {
                    app.path = [session.id]
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.title ?? "Session \(session.id)")
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(2)
                        HStack(spacing: 5) {
                            if let status = session.status { StatusBadge(status: status, compact: true) }
                            Text(verbatim: "#\(session.id)").font(Theme.mono).foregroundStyle(Theme.inkMute)
                            if let created = session.createdAt {
                                Text("·").foregroundStyle(Theme.inkMute)
                                Text(verbatim: Format.age(created))
                                    .accessibilityLabel(created.formatted(.relative(presentation: .named)))
                            }
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.inkSoft)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("trigger.detail.session.\(session.id)")
            }
        } header: {
            Text("Recent sessions").themeLabel()
        }
        .themeRows()
    }

    private var actions: some View {
        Menu {
            if let trigger = detail?.trigger {
                Button { runNow(trigger) } label: { Label("Run Now", systemImage: "play.fill") }
                Button {
                    Task { await toggle() }
                } label: {
                    Label(trigger.toggleLabel, systemImage: trigger.isEnabled ? "pause.circle" : "play.circle")
                }
                if let session = trigger.lastSessionID {
                    Button { app.path = [session] } label: { Label("Open Last Session", systemImage: "arrow.up.forward.app") }
                }
                Divider()
                Button { editing = true } label: { Label("Edit", systemImage: "pencil") }
                    .accessibilityIdentifier("trigger.edit")
                Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete", systemImage: "trash") }
                    .disabled(deleting)
                    .accessibilityIdentifier("trigger.delete")
            }
            // The two re-use switches are on its web page.
            if let url = app.webURL(path: "/triggers/\(id)") {
                Button { openURL(url) } label: { Label("Open in browser", systemImage: "safari") }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Trigger actions")
        .accessibilityIdentifier("trigger.detail.actions")
    }

    /// A setting's name on the left and its value on the right, in the page's quieter ink.
    private func row<Value: View>(_ title: String, @ViewBuilder value: () -> Value) -> some View {
        LabeledContent {
            value().font(.subheadline).foregroundStyle(Theme.ink)
        } label: {
            Text(title).font(.subheadline).foregroundStyle(Theme.inkSoft)
        }
    }

    private func onOff(_ on: Bool) -> Text {
        Text(on ? "On" : "Off")
    }

    /// The two settings that only mean something on a trigger that re-uses its session, which
    /// the web page says beside each one.
    private func reuseOption(_ title: String, on: Bool, reuse: Bool) -> some View {
        row(title) {
            if reuse { onOff(on) } else { Text("Needs session re-use").foregroundStyle(Theme.inkMute) }
        }
    }

    /// The web page's sentence beside the coalescing window.
    private func coalescingNote(_ trigger: TriggerSummary) -> String {
        if trigger.coalesceWindowInert { return "Inert — only Slack conditions coalesce, and this trigger has none." }
        if let seconds = trigger.effectiveCoalesceWindowSeconds, seconds > 0 {
            return "Slack messages in one channel within this window are one event and spawn one session; the rest are folded into its prompt."
        }
        return "Every message spawns its own session."
    }

    /// The catalog artifacts its sessions get, as the web page's chips: a name the catalog no
    /// longer resolves is kept on the trigger and flagged, since its sessions run without it.
    @ViewBuilder
    private func chips(_ title: String, _ names: [String], list: String, trigger: TriggerSummary, tone: Color) -> some View {
        if !names.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline).foregroundStyle(Theme.inkSoft)
                FlowLayout(spacing: 6, rowSpacing: 6) {
                    ForEach(names, id: \.self) { name in
                        let unresolved = trigger.catalogReferenceUnresolved(list, name)
                        Text(verbatim: unresolved ? "\(name) (not in catalog)" : name)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .foregroundStyle(unresolved ? Theme.danger : tone)
                            .background((unresolved ? Theme.danger : tone).opacity(0.14), in: Capsule())
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("trigger.detail.\(list)")
        }
    }

    /// Run Now: a template with variables opens the sheet to fill them; one without asks
    /// for a confirmation, as the web panel's bare Run does.
    private func runNow(_ trigger: TriggerSummary) {
        if trigger.promptVariables.isEmpty { confirmingInvoke = true } else { runningWithVariables = true }
    }

    private func failedHeadline(_ trigger: TriggerSummary) -> String {
        guard let at = trigger.failedAt else { return "This trigger failed to fire" }
        let age = Format.age(at)
        return age == "now" ? "This trigger failed to fire just now" : "This trigger failed to fire \(age) ago"
    }

    private func load() async {
        do {
            detail = try await app.api.trigger(id)
            error = nil
            if app.fixtureOpensRunNow {
                app.fixtureOpensRunNow = false
                runningWithVariables = true
            }
            if app.fixtureOpensTriggerForm {
                app.fixtureOpensTriggerForm = false
                editing = true
            }
        } catch {
            self.error = error as? ZimmerError ?? .transport(error)
            app.noteError(self.error!)
        }
    }

    private func toggle() async {
        guard !toggling, detail != nil else { return }
        toggling = true
        defer { toggling = false }
        do {
            let updated = try await app.api.toggleTrigger(id)
            detail?.trigger = updated
            notice = updated.isEnabled ? "\(updated.name) on" : "\(updated.name) off"
            Haptics.success()
        } catch {
            self.error = error as? ZimmerError ?? .transport(error)
            Haptics.failure()
        }
    }

    /// Gone from the server, so gone from the stack: the list behind this page reads again.
    private func delete() async {
        guard !deleting else { return }
        deleting = true
        defer { deleting = false }
        do {
            try await app.api.deleteTrigger(id)
            Haptics.success()
            dismiss()
        } catch {
            self.error = error as? ZimmerError ?? .transport(error)
            Haptics.failure()
        }
    }

    private func invoke(variables: [String: String] = [:]) async {
        do {
            let result = try await app.api.invokeTrigger(id, variables: variables)
            notice = result.notice
            if result.started { Haptics.success() } else { Haptics.failure() }
            await load()
            if let session = result.sessionID { app.path = [session] }
        } catch {
            self.error = error as? ZimmerError ?? .transport(error)
            Haptics.failure()
        }
    }
}

/// A trigger's status as the web page colours it: enabled in green, failed in red, off in gray.
private struct TriggerStatusBadge: View {
    let status: String

    var body: some View {
        Text(status.capitalized)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }

    private var color: Color {
        switch status {
        case "enabled": return Theme.success
        case "failed": return Theme.danger
        default: return Theme.inkMute
        }
    }
}
