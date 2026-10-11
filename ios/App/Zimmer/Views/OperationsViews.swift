import Charts
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
                                .tint(Theme.accent)
                    }
                }
                .listRowBackground(Theme.surface)
                .listRowSeparatorTint(Theme.rule)
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

private struct InboxRow: View {
    let notification: InboxNotification

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(notification.read ? Color.clear : Theme.accent)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 5) {
                Text(notification.headline)
                    .font(.subheadline.weight(notification.read ? .regular : .semibold))
                    .foregroundStyle(notification.read ? Theme.inkSoft : Theme.ink)
                if let session = notification.session {
                    Text(session.title ?? "Session \(session.id)")
                        .font(Theme.headline())
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    if let status = notification.session?.status { StatusBadge(status: status, compact: true) }
                    if let session = notification.session { Text(verbatim: "#\(session.id)").font(Theme.mono).foregroundStyle(Theme.inkMute) }
                    if let date = notification.createdAt {
                        Text("·").foregroundStyle(Theme.inkMute)
                        Text(date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.inkSoft)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// The web UI's triggers list: each one's status, what fires it, and when it last did.
/// Turn one on or off, or invoke it now. Creating and editing stay in the browser.
struct TriggersView: View {
    @EnvironmentObject private var app: AppModel
    @State private var triggers: [TriggerSummary]?
    @State private var error: ZimmerError?
    @State private var notice: String?
    @State private var invoking: TriggerSummary?
    /// Triggers with a toggle in flight: a second tap waits for the first.
    @State private var toggling: Set<Int> = []

    var body: some View {
        List {
            if let error { ErrorBanner(error: error).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
            ForEach(triggers ?? []) { trigger in
                TriggerRow(trigger: trigger) {
                    Task { await toggle(trigger) }
                }
                .swipeActions(edge: .trailing) {
                    Button { invoking = trigger } label: { Label("Invoke", systemImage: "play.fill") }
                        .tint(Theme.success)
                }
                .listRowBackground(Theme.surface)
                .listRowSeparatorTint(Theme.rule)
                .accessibilityElement(children: .contain)
                .contextMenu {
                    Button { invoking = trigger } label: { Label("Invoke Now", systemImage: "play.fill") }
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
        .refreshable { await load() }
        .task { await load() }
        .navigationTitle("Triggers")
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

    private func invoke(_ trigger: TriggerSummary) async {
        do {
            let result = try await app.api.invokeTrigger(trigger.id)
            // The web UI's Invoke tells these apart, and so does the toast: only a session that
            // was actually started is a success.
            switch result.outcome {
            case .started: notice = result.message
            case .burstNotice: notice = "Burst: no new session. \(result.message)"
            case .pendingSession: notice = "A session is still pending. \(result.message)"
            case .notReusable: notice = "Its session cannot take another turn. \(result.message)"
            }
            if result.started { Haptics.success() } else { Haptics.failure() }
            await load()
            if let id = result.sessionID { app.path = [id] }
        } catch {
            self.error = error as? ZimmerError ?? .transport(error)
            Haptics.failure()
        }
    }
}

private struct TriggerRow: View {
    let trigger: TriggerSummary
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(trigger.name).font(Theme.headline()).foregroundStyle(Theme.ink)
                ForEach(Array(trigger.conditions.enumerated()), id: \.offset) { _, condition in
                    Text(condition.description ?? condition.type ?? "condition")
                        .font(.caption)
                        .foregroundStyle(Theme.inkSoft)
                }
                HStack(spacing: 6) {
                    if let root = trigger.agentRoot { Text(root).font(Theme.mono) }
                    if let last = trigger.lastTriggeredAt {
                        Text("·").foregroundStyle(Theme.inkMute)
                        Text("fired \(last.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))")
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.inkMute)
                if trigger.status == "failed", let lastError = trigger.lastError {
                    Text(lastError).font(.caption).foregroundStyle(Theme.warning).lineLimit(3)
                }
            }
            Spacer()
            Toggle("Enabled", isOn: Binding(get: { trigger.isEnabled }, set: { _ in toggle() }))
                .labelsHidden()
                .tint(Theme.accent)
                .accessibilityIdentifier("trigger.toggle.\(trigger.id)")
        }
    }
}

/// Costs and Health, the web UI's other top-navigation pages, plus Settings.
struct MoreView: View {
    @State private var showingSettings = false

    var body: some View {
        List {
            Section {
                NavigationLink { CostsView() } label: { Label("Costs", systemImage: "dollarsign.circle") }
                    .accessibilityIdentifier("more.costs")
                NavigationLink { HealthView() } label: { Label("Health", systemImage: "heart.text.square") }
                    .accessibilityIdentifier("more.health")
                Button { showingSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                    .foregroundStyle(Theme.ink)
            }
            .listRowBackground(Theme.surface)
        }
        .themeGround()
        .navigationTitle("More")
        .sheet(isPresented: $showingSettings) { SettingsView() }
    }
}

/// The web UI's Costs page, read-only: the window's total, spend by day, and where it went.
struct CostsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var days = 7
    @State private var snapshot: CostSnapshot?
    @State private var error: ZimmerError?

    var body: some View {
        List {
            Picker("Window", selection: $days) {
                Text("7 days").tag(7)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            if let error { ErrorBanner(error: error).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
            if let snapshot {
                Section {
                    Text(snapshot.totalUSD, format: .currency(code: "USD"))
                        .font(.system(size: 40, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.ink)
                        .contentTransition(.numericText())
                        .accessibilityIdentifier("costs.total")
                    if !snapshot.days.isEmpty {
                        Chart(snapshot.days) { day in
                            BarMark(x: .value("Day", day.day), y: .value("USD", day.costUSD))
                                .foregroundStyle(Theme.accent)
                                .cornerRadius(3)
                        }
                        .chartXAxis(.hidden)
                        .frame(height: 140)
                        .accessibilityLabel("Spend by day")
                    }
                } header: {
                    Text("Last \(days) days").themeLabel()
                }
                .listRowBackground(Theme.surface)
                rows("By agent root", snapshot.agentRoots)
                rows("By model", snapshot.models)
                if !snapshot.topSessions.isEmpty {
                    Section {
                        ForEach(snapshot.topSessions) { top in
                            Button {
                                app.path = [top.sessionID]
                            } label: {
                                LabeledContent {
                                    Text(top.costUSD, format: .currency(code: "USD")).monospacedDigit()
                                } label: {
                                    Text(verbatim: "#\(top.sessionID)").font(.system(.body, design: .monospaced))
                                }
                            }
                            .foregroundStyle(Theme.ink)
                        }
                    } header: {
                        Text("Most expensive sessions").themeLabel()
                    }
                    .listRowBackground(Theme.surface)
                }
            }
        }
        .themeGround()
        .overlay { if snapshot == nil && error == nil { LoadingState() } }
        .task(id: days) { await load() }
        .refreshable { await load() }
        .navigationTitle("Costs")
    }

    @ViewBuilder
    private func rows(_ title: String, _ rows: [CostSnapshot.Row]) -> some View {
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row in
                    LabeledContent(row.label) { Text(row.costUSD, format: .currency(code: "USD")).monospacedDigit() }
                }
            } header: {
                Text(title).themeLabel()
            }
            .listRowBackground(Theme.surface)
        }
    }

    private func load() async {
        do {
            snapshot = try await app.api.costs(days: days)
            error = nil
        } catch {
            self.error = error as? ZimmerError ?? .transport(error)
        }
    }
}

/// The web UI's Health page, read-only: the overall status, then each section's. Its operator
/// actions (cleanup, retries, queue recovery) stay in the browser.
struct HealthView: View {
    @EnvironmentObject private var app: AppModel
    @State private var report: HealthReport?
    @State private var error: ZimmerError?

    var body: some View {
        List {
            if let error { ErrorBanner(error: error).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
            if let report {
                Section {
                    row(report.overall, title: "Overall").accessibilityIdentifier("health.overall")
                } footer: {
                    if let at = report.generatedAt { Text("Checked \(at.formatted(.relative(presentation: .named)))") }
                }
                .listRowBackground(Theme.surface)
                Section {
                    ForEach(report.sections) { section in row(section, title: section.title) }
                } header: {
                    Text("Sections").themeLabel()
                }
                .listRowBackground(Theme.surface)
            }
        }
        .themeGround()
        .overlay { if report == nil && error == nil { LoadingState() } }
        .task { await load() }
        .refreshable { await load() }
        .navigationTitle("Health")
    }

    private func row(_ section: HealthReport.Section, title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).foregroundStyle(Theme.ink)
                Spacer()
                Text(section.status.capitalized)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .foregroundStyle(Self.color(section.status))
                    .background(Self.color(section.status).opacity(0.14), in: Capsule())
            }
            if let message = section.message {
                Text(message).font(.caption).foregroundStyle(Theme.inkSoft)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The web UI's health colours.
    static func color(_ status: String) -> Color {
        switch status {
        case "healthy": return Theme.success
        case "warning": return Theme.warning
        case "critical": return Theme.danger
        default: return Theme.inkMute
        }
    }

    private func load() async {
        do {
            report = try await app.api.health()
            error = nil
        } catch {
            self.error = error as? ZimmerError ?? .transport(error)
        }
    }
}
