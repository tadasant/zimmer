import SwiftUI
import ZimmerKit

/// The tab bar: the web UI's top navigation, as iOS tabs.
enum AppTab: String, Hashable {
    case sessions, inbox, triggers, more
}

/// The web UI's notifications inbox: newest first, unread in bold. Tap one to open its
/// session (and mark it read); swipe to mark read or dismiss a read one.
struct InboxView: View {
    @EnvironmentObject private var app: AppModel
    @State private var notifications: [InboxNotification]?
    @State private var error: ZimmerError?
    @State private var notice: String?

    var body: some View {
        List {
            if let error { ErrorBanner(error: error).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
            ForEach(notifications ?? []) { notification in
                Button {
                    Task { await open(notification) }
                } label: {
                    InboxRow(notification: notification)
                }
                .accessibilityIdentifier("inbox.\(notification.id)")
                .swipeActions(edge: .trailing) {
                    if notification.read {
                        Button(role: .destructive) {
                            Task { await act("Dismissed") { try await $0.dismissNotification(notification.id) } }
                        } label: {
                            Label("Dismiss", systemImage: "xmark")
                        }
                    } else {
                        Button {
                            Task { await act("Marked read") { _ = try await $0.markNotificationRead(notification.id) } }
                        } label: {
                            Label("Mark Read", systemImage: "envelope.open")
                        }
                        .tint(Theme.Swipe.snooze)
                    }
                }
                .themeRows()
                .listRowInsets(EdgeInsets(top: 9, leading: 20, bottom: 9, trailing: 16))
            }
        }
        .listStyle(.insetGrouped)
        .themeGround()
        .overlay {
            if notifications == nil && error == nil { LoadingState() }
            if notifications?.isEmpty == true {
                EmptyState(title: "No notifications", symbol: "bell.slash", message: "When a session needs you, it shows up here.")
            }
        }
        .overlay(alignment: .bottom) { Toast(text: $notice) }
        .refreshable { await load() }
        .task { await load() }
        .navigationTitle("Notifications")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { await act("All marked read") { try await $0.markAllNotificationsRead() } }
                    } label: {
                        Label("Mark All Read", systemImage: "envelope.open")
                    }
                    Button(role: .destructive) {
                        Task { await act("Read notifications dismissed") { try await $0.dismissAllReadNotifications() } }
                    } label: {
                        Label("Dismiss All Read", systemImage: "xmark")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Inbox actions")
                .accessibilityIdentifier("inbox.actions")
            }
        }
    }

    private func load() async {
        do {
            notifications = try await app.api.notifications()
            error = nil
        } catch {
            self.error = error as? ZimmerError ?? .transport(error)
            app.noteError(self.error!)
            if notifications == nil { notifications = [] }
        }
        await app.refreshUnreadCount()
    }

    /// Open the session it is about, marking it read on the way, as the web UI's click does.
    private func open(_ notification: InboxNotification) async {
        if !notification.read { _ = try? await app.api.markNotificationRead(notification.id) }
        await app.refreshUnreadCount()
        if let id = notification.session?.id { app.path = [id] }
        await load()
    }

    private func act(_ done: String, _ action: (ZimmerAPI) async throws -> Void) async {
        do {
            try await action(app.api)
            notice = done
            Haptics.success()
            await load()
        } catch {
            // Not followed by a reload, which would clear the refusal before anyone read it.
            self.error = error as? ZimmerError ?? .transport(error)
            Haptics.failure()
        }
    }
}

/// One notification, in the board's row shape: the kind as a small label, the session's
/// title, then one line of status, id and age. Unread rows are in the full ink with a dot;
/// read ones in the quieter ink, as Motet dims what is done.
private struct InboxRow: View {
    let notification: InboxNotification

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(notification.read ? Color.clear : Theme.accent)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(notification.headline)
                    .themeLabel(size: 10, color: notification.read ? Theme.inkMute : Theme.accent)
                if let session = notification.session {
                    Text(session.title ?? "Session \(session.id)")
                        .font(.system(.subheadline, weight: notification.read ? .medium : .semibold))
                        .foregroundStyle(notification.read ? Theme.inkSoft : Theme.ink)
                        .lineLimit(2)
                }
                HStack(spacing: 5) {
                    if let status = notification.session?.status { StatusBadge(status: status, compact: true) }
                    if let session = notification.session { Text(verbatim: "#\(session.id)").font(Theme.mono).foregroundStyle(Theme.inkMute) }
                    if let date = notification.createdAt {
                        Text("·").foregroundStyle(Theme.inkMute)
                        Text(verbatim: Format.age(date))
                            .accessibilityLabel(date.formatted(.relative(presentation: .named)))
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.inkSoft)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The web UI's triggers list: each one's status, what fires it, and when it last did.
/// Turn one on or off, or invoke it now; tap one for its page. Creating and editing stay in
/// the browser.
struct TriggersView: View {
    @EnvironmentObject private var app: AppModel
    @State private var triggers: [TriggerSummary]?
    @State private var error: ZimmerError?
    @State private var notice: String?
    @State private var invoking: TriggerSummary?
    /// A trigger whose template has variables to fill before it runs.
    @State private var runningWithVariables: TriggerSummary?
    /// The trigger whose page is open.
    @State private var opened: Int?
    /// Triggers with a toggle in flight: a second tap waits for the first.
    @State private var toggling: Set<Int> = []

    var body: some View {
        List {
            if let error { ErrorBanner(error: error).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
            ForEach(triggers ?? []) { trigger in
                TriggerRow(trigger: trigger) {
                    opened = trigger.id
                } toggle: {
                    Task { await toggle(trigger) }
                }
                .swipeActions(edge: .trailing) {
                    Button { runNow(trigger) } label: { Label("Invoke", systemImage: "play.fill") }
                        .tint(Theme.Swipe.restore)
                }
                .themeRows()
                .listRowInsets(EdgeInsets(top: 9, leading: 20, bottom: 9, trailing: 16))
                .accessibilityElement(children: .contain)
                .contextMenu {
                    Button { opened = trigger.id } label: { Label("Open", systemImage: "info.circle") }
                    Button { runNow(trigger) } label: { Label("Invoke Now", systemImage: "play.fill") }
                    if let id = trigger.lastSessionID {
                        Button { app.path = [id] } label: { Label("Open Last Session", systemImage: "arrow.up.forward.app") }
                    }
                }
                .accessibilityIdentifier("trigger.\(trigger.id)")
            }
        }
        .themeGround()
        .overlay {
            if triggers == nil && error == nil { LoadingState() }
            if triggers?.isEmpty == true {
                EmptyState(title: "No triggers", symbol: "bolt.slash", message: "Create one in the browser; it shows up here.")
            }
        }
        .overlay(alignment: .bottom) { Toast(text: $notice) }
        .confirmationDialog(
            "Invoke now?",
            isPresented: Binding(get: { invoking != nil }, set: { if !$0 { invoking = nil } }),
            titleVisibility: .visible,
            presenting: invoking
        ) { trigger in
            Button("Invoke \(trigger.name)") { Task { await invoke(trigger) } }
                .accessibilityIdentifier("trigger.invoke.confirm")
        } message: { _ in
            Text("It fires as if its condition had matched, as the web UI's Invoke does.")
        }
        .sheet(item: $runningWithVariables) { trigger in
            TriggerRunSheet(trigger: trigger) { variables in await invoke(trigger, variables: variables) }
        }
        .refreshable { await load() }
        .task { await load() }
        .navigationTitle("Triggers")
        .navigationDestination(item: $opened) { id in TriggerDetailView(id: id) }
        .onChange(of: app.fixtureTrigger, initial: true) { _, id in
            guard let id else { return }
            opened = id
            app.fixtureTrigger = nil
        }
    }

    private func load() async {
        do {
            triggers = try await app.api.triggers()
            error = nil
        } catch {
            self.error = error as? ZimmerError ?? .transport(error)
            app.noteError(self.error!)
            if triggers == nil { triggers = [] }
        }
    }

    private func toggle(_ trigger: TriggerSummary) async {
        guard toggling.insert(trigger.id).inserted else { return }
        defer { toggling.remove(trigger.id) }
        do {
            let updated = try await app.api.toggleTrigger(trigger.id)
            if let index = triggers?.firstIndex(where: { $0.id == trigger.id }) { triggers?[index] = updated }
            notice = updated.isEnabled ? "\(updated.name) on" : "\(updated.name) off"
            Haptics.success()
        } catch {
            self.error = error as? ZimmerError ?? .transport(error)
            Haptics.failure()
        }
    }

    /// A template with variables opens the sheet to fill them; one without asks for a confirmation.
    private func runNow(_ trigger: TriggerSummary) {
        if trigger.promptVariables.isEmpty { invoking = trigger } else { runningWithVariables = trigger }
    }

    private func invoke(_ trigger: TriggerSummary, variables: [String: String] = [:]) async {
        do {
            let result = try await app.api.invokeTrigger(trigger.id, variables: variables)
            notice = result.notice
            if result.started { Haptics.success() } else { Haptics.failure() }
            await load()
            if let id = result.sessionID { app.path = [id] }
        } catch {
            self.error = error as? ZimmerError ?? .transport(error)
            Haptics.failure()
        }
    }
}

/// One trigger, in the board's row shape: the name, what fires it on one line, then the
/// root, when it last fired and how many sessions it has made. A trigger that is off reads
/// in the quieter ink. The words open its page; the switch beside them stays its own control.
private struct TriggerRow: View {
    let trigger: TriggerSummary
    let open: () -> Void
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: open) { summary }
                .buttonStyle(.plain)
                .accessibilityIdentifier("trigger.open.\(trigger.id)")
            Toggle("Enabled", isOn: Binding(get: { trigger.isEnabled }, set: { _ in toggle() }))
                .labelsHidden()
                .tint(Theme.accent)
                .accessibilityIdentifier("trigger.toggle.\(trigger.id)")
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(trigger.name)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(trigger.isEnabled ? Theme.ink : Theme.inkSoft)
                .lineLimit(2)
            if !trigger.conditions.isEmpty {
                Text(verbatim: trigger.conditions.map { $0.description ?? $0.type ?? "condition" }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(Theme.inkSoft)
                    .lineLimit(2)
            }
            HStack(spacing: 5) {
                if let root = trigger.agentRoot { Text(root).font(Theme.mono) }
                if let last = trigger.lastTriggeredAt {
                    if trigger.agentRoot != nil { Text("·") }
                    let age = Format.age(last)
                    Text(verbatim: age == "now" ? "fired just now" : "fired \(age)")
                        .accessibilityLabel("fired \(last.formatted(.relative(presentation: .named)))")
                }
                if let count = trigger.sessionsCreated, count > 0 {
                    if trigger.agentRoot != nil || trigger.lastTriggeredAt != nil { Text("·") }
                    Text(verbatim: "\(count) sessions")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Theme.inkMute)
            if trigger.isFailed, let lastError = trigger.lastError {
                Text(lastError).font(.caption).foregroundStyle(Theme.warning).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Costs, Health and CLIs, the web UI's other top-navigation pages, plus Settings.
struct MoreView: View {
    @EnvironmentObject private var app: AppModel
    @State private var showingSettings = false
    /// Costs opened by a fixture launch, narrowed as it asked.
    @State private var openedCosts: CostScope?
    @State private var openedHealth = false
    @State private var openedClis = false

    var body: some View {
        List {
            Section {
                NavigationLink { CostsView() } label: { row("Costs", "dollarsign.circle", "Coverage, spend by day, root, feature, model and session, burn rates") }
                    .accessibilityIdentifier("more.costs")
                NavigationLink { HealthView() } label: { row("Health", "heart.text.square", "Every section of the health page, and its operator actions") }
                    .accessibilityIdentifier("more.health")
                NavigationLink { CliToolsView() } label: {
                    row("CLIs", "terminal", "Which command-line tools are installed and signed in", badge: app.cliIssues)
                }
                .accessibilityIdentifier("more.clis")
            }
            .themeRows()
            Section {
                Button { showingSettings = true } label: { row("Settings", "gearshape", "Sign-in, notifications, this build") }
            }
            .themeRows()
        }
        .listStyle(.insetGrouped)
        .themeGround()
        .navigationTitle("More")
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .navigationDestination(item: $openedCosts) { scope in CostsView(scope: scope) }
        .navigationDestination(isPresented: $openedHealth) { HealthView() }
        .navigationDestination(isPresented: $openedClis) { CliToolsView() }
        .task { await app.refreshCliIssues() }
        .onChange(of: app.fixtureCosts, initial: true) { _, scope in
            guard let scope else { return }
            openedCosts = scope
            app.fixtureCosts = nil
        }
        .onChange(of: app.fixtureHealth, initial: true) { _, open in
            guard open else { return }
            openedHealth = true
            app.fixtureHealth = false
        }
        .onChange(of: app.fixtureClis, initial: true) { _, open in
            guard open else { return }
            openedClis = true
            app.fixtureClis = false
        }
    }

    /// A row with a glyph, a name and a line of what is behind it; `badge` is the web board's
    /// red count on its CLIs button, the tools that need attention.
    private func row(_ title: String, _ symbol: String, _ detail: String, badge: Int = 0) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(.subheadline, weight: .medium)).foregroundStyle(Theme.ink)
                Text(detail).font(.caption).foregroundStyle(Theme.inkSoft)
            }
            if badge > 0 {
                Spacer()
                Text(verbatim: "\(badge)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Theme.danger, in: Capsule())
                    .accessibilityLabel("\(badge) CLI tools need attention")
                    .accessibilityIdentifier("more.clis.badge")
            }
        }
        .padding(.vertical, 2)
    }
}
