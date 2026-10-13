import SwiftUI
import ZimmerKit

/// The web UI's trigger page, in the parts that matter on a phone: its status and the labels
/// beside its name, why it failed if it did, when it last fired and the session it last
/// started, what fires it, the root and settings its sessions get, its prompt, and the
/// sessions it made. Turn it on or off (or re-arm it), or invoke it now. Editing it, and its
/// two re-use switches, stay on the page in the browser.
struct TriggerDetailView: View {
    let id: Int
    @EnvironmentObject private var app: AppModel
    @Environment(\.openURL) private var openURL
    @State private var detail: TriggerDetail?
    @State private var error: ZimmerError?
    @State private var notice: String?
    @State private var confirmingInvoke = false
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
            }
            row("Session re-use") { onOff(trigger.reuseSession) }
            reuseOption("Enqueue messages", on: trigger.enqueueMessages, reuse: trigger.reuseSession)
                .accessibilityIdentifier("trigger.detail.enqueue")
            reuseOption("Resuscitate archived", on: trigger.resuscitateArchived, reuse: trigger.reuseSession)
                .accessibilityIdentifier("trigger.detail.resuscitate")
            row("Max sessions / minute") {
                if let max = trigger.maxSessionsPerMinute { Text(verbatim: "\(max)").monospacedDigit() } else { Text("No limit") }
            }
            if let goal = trigger.goal, !goal.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Goal").font(.subheadline).foregroundStyle(Theme.inkSoft)
                    Text(goal).font(.subheadline).foregroundStyle(Theme.ink)
                }
            }
        } header: {
            Text("Sessions it starts").themeLabel()
        } footer: {
            Text("Enqueue messages and Resuscitate archived are switched on the trigger's page in the browser, with the rest of its settings.")
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
            } header: {
                Text("Prompt template").themeLabel()
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
                Button { confirmingInvoke = true } label: { Label("Invoke Now", systemImage: "play.fill") }
                Button {
                    Task { await toggle() }
                } label: {
                    Label(trigger.toggleLabel, systemImage: trigger.isEnabled ? "pause.circle" : "play.circle")
                }
                if let session = trigger.lastSessionID {
                    Button { app.path = [session] } label: { Label("Open Last Session", systemImage: "arrow.up.forward.app") }
                }
            }
            // Editing a trigger, and its re-use switches, are on its web page.
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

    private func failedHeadline(_ trigger: TriggerSummary) -> String {
        guard let at = trigger.failedAt else { return "This trigger failed to fire" }
        let age = Format.age(at)
        return age == "now" ? "This trigger failed to fire just now" : "This trigger failed to fire \(age) ago"
    }

    private func load() async {
        do {
            detail = try await app.api.trigger(id)
            error = nil
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

    private func invoke() async {
        do {
            let result = try await app.api.invokeTrigger(id)
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
