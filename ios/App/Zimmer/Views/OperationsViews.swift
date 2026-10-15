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
                    Button { invoking = trigger } label: { Label("Invoke", systemImage: "play.fill") }
                        .tint(Theme.Swipe.restore)
                }
                .themeRows()
                .listRowInsets(EdgeInsets(top: 9, leading: 20, bottom: 9, trailing: 16))
                .accessibilityElement(children: .contain)
                .contextMenu {
                    Button { opened = trigger.id } label: { Label("Open", systemImage: "info.circle") }
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

    private func invoke(_ trigger: TriggerSummary) async {
        do {
            let result = try await app.api.invokeTrigger(trigger.id)
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

/// Costs and Health, the web UI's other top-navigation pages, plus Settings.
struct MoreView: View {
    @EnvironmentObject private var app: AppModel
    @State private var showingSettings = false
    /// Costs opened by a fixture launch, narrowed as it asked.
    @State private var openedCosts: CostScope?
    /// Settings opened by a fixture launch, at the section it asked for.
    @State private var openedSettings: SettingsOpening?

    var body: some View {
        List {
            Section {
                NavigationLink { CostsView() } label: { row("Costs", "dollarsign.circle", "Spend by day, root, model and session") }
                    .accessibilityIdentifier("more.costs")
                NavigationLink { HealthView() } label: { row("Health", "heart.text.square", "Processes, sessions and the system") }
                    .accessibilityIdentifier("more.health")
            }
            .themeRows()
            Section {
                Button { showingSettings = true } label: { row("Settings", "gearshape", "Sign-in, API keys, session defaults, experimental, MCP Apps, notifications") }
                    .accessibilityIdentifier("more.settings")
            }
            .themeRows()
        }
        .listStyle(.insetGrouped)
        .themeGround()
        .navigationTitle("More")
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .sheet(item: $openedSettings) { opening in SettingsView(opensAt: opening.section, opensAccount: opening.account) }
        .navigationDestination(item: $openedCosts) { scope in CostsView(scope: scope) }
        .onChange(of: app.fixtureCosts, initial: true) { _, scope in
            guard let scope else { return }
            openedCosts = scope
            app.fixtureCosts = nil
        }
        .onChange(of: app.fixtureSettings, initial: true) { _, opening in
            guard let opening else { return }
            openedSettings = opening
            app.fixtureSettings = nil
        }
    }

    /// A row with a glyph, a name and a line of what is behind it.
    private func row(_ title: String, _ symbol: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(.subheadline, weight: .medium)).foregroundStyle(Theme.ink)
                Text(detail).font(.caption).foregroundStyle(Theme.inkSoft)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The web UI's Costs page, read-only: the window's total, spend by day, and where it went.
/// The window is a one-tap horizon or a calendar range, and the page narrows to one agent
/// root or one session, as the web page's drilldown does.
struct CostsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var window: CostWindow = .days(7)
    @State private var scope: CostScope
    /// The narrowed session's title, when it was narrowed from a row that had one.
    @State private var scopeTitle: String?
    @State private var snapshot: CostSnapshot?
    @State private var error: ZimmerError?
    /// The calendar range's two fields, pre-filled with the window on screen, as the web
    /// form's are.
    @State private var rangeFrom = Date()
    @State private var rangeTo = Date()

    init(scope: CostScope = .fleet) {
        _scope = State(initialValue: scope)
    }

    /// What the page is reading; a change to either reloads it.
    private struct Request: Equatable {
        var window: CostWindow
        var scope: CostScope
    }

    var body: some View {
        List {
            windowPicker
            if !shownScope.isFleet { scopeBanner }
            if let error { ErrorBanner(error: error).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
            if let snapshot {
                Section {
                    Text(snapshot.totalUSD, format: .currency(code: "USD"))
                        .font(.system(size: 34, weight: .semibold).monospacedDigit())
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
                    Text(window.label()).themeLabel()
                }
                .themeRows()
                agentRootRows(snapshot.agentRoots)
                rows("By model", snapshot.models)
                if !snapshot.topSessions.isEmpty {
                    Section {
                        ForEach(snapshot.topSessions) { top in
                            topSessionRow(top)
                        }
                    } header: {
                        Text("Most expensive sessions").themeLabel()
                    } footer: {
                        if scope.isFleet {
                            Text("Swipe a session to narrow the page to it.").font(.caption).foregroundStyle(Theme.inkMute)
                        }
                    }
                    .themeRows()
                }
            }
        }
        .themeGround()
        .overlay { if snapshot == nil && error == nil { LoadingState() } }
        .task(id: Request(window: window, scope: scope)) { await load() }
        .refreshable { await load() }
        .navigationTitle("Costs")
    }

    /// The web page's horizons and its calendar range, side by side: the horizons answer
    /// "what happened this week" in one tap, the range "what did that week in July cost".
    @ViewBuilder
    private var windowPicker: some View {
        Section {
            Picker("Window", selection: presetSelection) {
                ForEach(CostWindow.presets) { preset in
                    Text(preset.label).tag(preset.days)
                }
                Text("Custom").tag(0)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("costs.window")
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
        }
        Section {
            DatePicker("From", selection: $rangeFrom, in: ...Date(), displayedComponents: .date)
                .accessibilityIdentifier("costs.range.from")
            DatePicker("To", selection: $rangeTo, in: ...Date(), displayedComponents: .date)
                .accessibilityIdentifier("costs.range.to")
            Button("Show This Range") { showRange() }
                .foregroundStyle(Theme.accent)
                .accessibilityIdentifier("costs.range.apply")
        } footer: {
            Text("Showing \(window.label())").font(.caption).foregroundStyle(Theme.inkMute)
                .accessibilityIdentifier("costs.showing")
        }
        .font(.subheadline)
        .tint(Theme.accent)
        .themeRows()
    }

    /// The segment for the window on screen; Custom (0) for a calendar range. Choosing Custom
    /// shows the range in the two fields.
    private var presetSelection: Binding<Int> {
        Binding {
            if case let .days(days) = window { return days }
            return 0
        } set: { days in
            if days == 0 { showRange() } else { window = .days(days) }
        }
    }

    /// The two fields as a window, and the fields set to what it resolved to: swapped if
    /// they were the wrong way round, a year at most.
    private func showRange() {
        let range = CostWindow.custom(from: rangeFrom, to: rangeTo)
        if case let .range(from, to) = range {
            rangeFrom = from
            rangeTo = to
        }
        window = range
    }

    /// What the figures on screen cover, as the server read the request: until a new
    /// scope's figures arrive, the banner keeps describing the ones still showing.
    private var shownScope: CostScope {
        snapshot?.scope ?? scope
    }

    /// The drilldown's own statement of what it is, without which a narrowed page reads as a
    /// fleet page on a quiet day — and the way back to every root.
    private var scopeBanner: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                switch shownScope {
                case let .agentRoot(root):
                    HStack(spacing: 5) {
                        Text("Agent root").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                        Text(root).font(.system(.subheadline, design: .monospaced).weight(.semibold)).foregroundStyle(Theme.ink)
                    }
                    Text("Every figure covers this agent root only, over \(window.label()). Ad hoc calls are Zimmer's own inference, made outside any session, so they carry no agent root and are left out.")
                        .font(.caption)
                        .foregroundStyle(Theme.inkSoft)
                case let .session(id):
                    Button {
                        app.path = [id]
                    } label: {
                        Text(verbatim: sessionTitle(id).map { "Session #\(id) — \($0)" } ?? "Session #\(id)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    Text("Every figure covers this session only, over \(window.label()). Ad hoc calls made about it, its generated title and push summaries, are included.")
                        .font(.caption)
                        .foregroundStyle(Theme.inkSoft)
                case .fleet:
                    EmptyView()
                }
                Button("All agent roots") {
                    scope = .fleet
                    scopeTitle = nil
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .buttonStyle(.borderless)
                .padding(.top, 2)
                .accessibilityIdentifier("costs.scope.clear")
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("costs.scope")
        }
        .themeRows()
    }

    private func sessionTitle(_ id: Int) -> String? {
        scopeTitle ?? snapshot?.topSessions.first(where: { $0.sessionID == id })?.title
    }

    /// By agent root. On the fleet page a root narrows the whole page to itself; the folded
    /// "other (N)" bucket is several roots and so not one thing to narrow to.
    @ViewBuilder
    private func agentRootRows(_ rows: [CostSnapshot.Row]) -> some View {
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row in
                    if scope.isFleet && CostScope.narrowable(agentRoot: row.label) {
                        Button {
                            scope = .agentRoot(row.label)
                        } label: {
                            LabeledContent {
                                HStack(spacing: 6) {
                                    Text(row.costUSD, format: .currency(code: "USD")).font(.subheadline.monospacedDigit()).foregroundStyle(Theme.ink)
                                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(Theme.inkMute)
                                }
                            } label: {
                                Text(row.label).font(.subheadline).foregroundStyle(Theme.ink)
                            }
                        }
                        .accessibilityIdentifier("costs.root.\(row.label)")
                    } else {
                        costRow(row)
                    }
                }
            } header: {
                Text("By agent root").themeLabel()
            }
            .themeRows()
        }
    }

    private func topSessionRow(_ top: CostSnapshot.TopSession) -> some View {
        Button {
            app.path = [top.sessionID]
        } label: {
            LabeledContent {
                Text(top.costUSD, format: .currency(code: "USD")).font(.subheadline.monospacedDigit())
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    if let title = top.title, !title.isEmpty {
                        Text(title).font(.subheadline).lineLimit(1)
                    }
                    HStack(spacing: 5) {
                        Text(verbatim: "#\(top.sessionID)").font(Theme.mono)
                        if let calls = top.apiCalls {
                            Text(verbatim: "· \(calls.formatted()) calls")
                        }
                        if let tokens = top.tokens {
                            Text(verbatim: "· \(tokens.formatted(.number.notation(.compactName))) tokens")
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.inkMute)
                }
            }
        }
        .foregroundStyle(Theme.ink)
        .accessibilityIdentifier("costs.session.\(top.sessionID)")
        .swipeActions(edge: .trailing) {
            if scope.isFleet {
                Button {
                    narrow(to: top)
                } label: {
                    Label("Only This", systemImage: "scope")
                }
                .tint(Theme.Swipe.snooze)
            }
        }
        .contextMenu {
            Button { app.path = [top.sessionID] } label: { Label("Open Session", systemImage: "arrow.up.forward.app") }
            if scope.isFleet {
                Button { narrow(to: top) } label: { Label("Only This Session", systemImage: "scope") }
            }
        }
    }

    private func narrow(to top: CostSnapshot.TopSession) {
        scopeTitle = top.title
        scope = .session(top.sessionID)
    }

    private func costRow(_ row: CostSnapshot.Row) -> some View {
        LabeledContent {
            Text(row.costUSD, format: .currency(code: "USD")).font(.subheadline.monospacedDigit()).foregroundStyle(Theme.ink)
        } label: {
            Text(row.label).font(.subheadline).foregroundStyle(Theme.ink)
        }
    }

    @ViewBuilder
    private func rows(_ title: String, _ rows: [CostSnapshot.Row]) -> some View {
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row in costRow(row) }
            } header: {
                Text(title).themeLabel()
            }
            .themeRows()
        }
    }

    private func load() async {
        do {
            let loaded = try await app.api.costs(window, scope: scope)
            // A window or scope chosen since this was asked for has its own load running.
            guard !Task.isCancelled else { return }
            snapshot = loaded
            error = nil
            // A horizon fills the range's fields with its own bounds, so opening the calendar
            // starts from what is on screen.
            if !window.isCustom, let from = loaded.from, let to = loaded.to {
                rangeFrom = from
                rangeTo = to
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error as? ZimmerError ?? .transport(error)
            app.noteError(self.error!)
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
                    if let at = report.generatedAt {
                        // The report is stamped as it is read, so "just now" is the usual case.
                        let age = Format.age(at)
                        Text(verbatim: age == "now" ? "Checked just now" : "Checked \(age) ago").font(.caption).foregroundStyle(Theme.inkMute)
                    }
                }
                .themeRows()
                Section {
                    ForEach(report.sections) { section in row(section, title: section.title) }
                } header: {
                    Text("Sections").themeLabel()
                }
                .themeRows()
            }
        }
        .themeGround()
        .overlay { if report == nil && error == nil { LoadingState() } }
        .task { await load() }
        .refreshable { await load() }
        .navigationTitle("Health")
    }

    private func row(_ section: HealthReport.Section, title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.subheadline).foregroundStyle(Theme.ink)
                Spacer()
                Text(section.status.capitalized)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .foregroundStyle(Self.color(section.status))
                    .background(Self.color(section.status).opacity(0.14), in: Capsule())
            }
            if let message = section.message {
                Text(message).font(.caption).foregroundStyle(Theme.inkSoft).lineLimit(3)
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
