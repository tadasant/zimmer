import SwiftUI
import ZimmerKit

/// Sessions, in one of the web UI's four board views, filtered by status and by board
/// visibility as the web UI's board is. "Needs input" is the default filter and the first
/// chip: the phone is for the sessions waiting on a person. Swipe right to star, left to
/// trash or snooze; press and hold for everything else the web UI's card offers; Select to
/// trash several at once. The Quick Router bar is pinned to the foot: the board is where
/// work starts.
struct SessionListView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingSettings = false
    @State private var snoozing: SessionSummary?
    @State private var trashing: SessionSummary?
    /// The search the list last loaded, so appearing does not reload a list `start()` just loaded.
    @State private var appliedSearch = SearchKey(text: "", scope: .titles)
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<Int>()
    @State private var confirmingBulkTrash = false
    @State private var confirmingRefreshAll = false
    /// The Ranked view's drag-and-drop, as an edit mode of its own: handles on the spot queue.
    @State private var reordering = false

    var body: some View {
        searchableList
            .toolbar { toolbarContent }
            .confirmationDialog(
                "Snooze until…", isPresented: isSnoozing,
                titleVisibility: .visible, presenting: snoozing
            ) { session in
                SnoozeButtons(session: session)
            } message: { _ in
                Text("Visual only — it does not pause, start or stop the session.")
            }
            .confirmationDialog(
                "Move to trash?", isPresented: isTrashing,
                titleVisibility: .visible, presenting: trashing
            ) { session in
                Button("Trash", role: .destructive) {
                    Task { await model.perform("Moved to trash", on: session.id) { try await $0.archive(session.id) } }
                }
            } message: { _ in
                Text("It moves to the trash. You can restore it from Archived.")
            }
            .confirmationDialog("Move \(selection.count) to trash?", isPresented: $confirmingBulkTrash, titleVisibility: .visible) {
                Button("Trash \(selection.count)", role: .destructive) {
                    let ids = selection
                    Task {
                        await model.trash(ids)
                        selection = []
                        editMode = .inactive
                    }
                }
            } message: {
                Text("A session mid-turn, or with messages still queued, is refused and stays.")
            }
            .confirmationDialog("Refresh all sessions?", isPresented: $confirmingRefreshAll, titleVisibility: .visible) {
                Button("Refresh All Now") { Task { await model.refreshAll() } }
            } message: {
                Text("Re-reads transcripts, restarts failed sessions, and continues sessions waiting on you that you didn't pause — up to 50 of those. That spends agent turns.")
            }
            .environment(\.editMode, $editMode)
            // Selecting hides the tab bar, as Mail does: the Trash bar takes its place at the bottom.
            .toolbar(editMode.isEditing ? .hidden : .visible, for: .tabBar)
            // A selection only ever names rows on screen: a filter, search or view change drops the rest.
            .onChange(of: model.sessions.map(\.id)) { _, ids in selection.formIntersection(ids) }
            // The server orders each view, so a new view is a new list.
            .onChange(of: model.view) { _, view in
                if view != .ranked, reordering { reordering = false; editMode = .inactive }
                Task { await model.viewChanged() }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
    }

    private var list: some View {
        // Selection is bound only while selecting: a List with a selection binding takes a
        // tap on a row as a selection, not as opening the session.
        List(selection: isSelecting ? $selection : nil) {
            Section {
                FilterBar()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } footer: {
                if model.board != .onBoard {
                    Label("Showing: \(model.board.label)", systemImage: "eye")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.snooze)
                        .accessibilityIdentifier("board.current")
                }
            }
            if let error = model.error {
                Section {
                    ErrorBanner(error: error)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            if model.sessions.isEmpty && !model.isLoading {
                Section {
                    EmptyListRow(filters: model.effectiveFilters, searching: !model.searchText.isEmpty)
                        .listRowBackground(Color.clear)
                }
            }
            ForEach(model.sessions.isEmpty ? [] : model.sections) { section in
                Section {
                    ForEach(section.sessions) { session in
                        SwipeableSessionRow(session: session, snoozing: $snoozing, trashing: $trashing)
                    }
                    .onMove(perform: moveHandler(for: section))
                    if section.sessions.isEmpty {
                        Text("None.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.inkMute)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    if let title = section.title {
                        Text(title)
                            .themeLabel()
                            .accessibilityIdentifier("section.\(title)")
                    }
                }
            }
            if model.listIncomplete {
                Section {} footer: {
                    Text(incompleteNotice).accessibilityIdentifier("list.incomplete")
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .themeGround()
        // Rows arriving, leaving and reordering slide rather than jump.
        .animation(.snappy(duration: 0.3), value: model.sessions.map(\.id))
        .navigationTitle("Sessions")
        .navigationBarTitleDisplayMode(.large)
    }

    private var isSelecting: Bool { editMode.isEditing && !reordering }

    /// Drag handles on the Ranked view's spot queue while reordering, and nowhere else.
    private func moveHandler(for section: BoardSection) -> ((IndexSet, Int) -> Void)? {
        guard reordering, section.title == "Spot queue" else { return nil }
        return { source, destination in drop(section.sessions, from: source, to: destination) }
    }

    /// A drop in the spot queue: the server is told the rows it landed between and works out
    /// the precedence, as the web UI's Ranked view does.
    private func drop(_ rows: [SessionSummary], from source: IndexSet, to destination: Int) {
        var moved = rows
        moved.move(fromOffsets: source, toOffset: destination)
        guard let from = source.first, let index = moved.firstIndex(where: { $0.id == rows[from].id }) else { return }
        let session = moved[index]
        let above = index > 0 ? moved[index - 1].id : nil
        let below = index < moved.count - 1 ? moved[index + 1].id : nil
        Task { await model.reorder(session.id, above: above, below: below) }
    }

    private var incompleteNotice: String {
        model.searchText.isEmpty
            ? "Showing the first \(SessionFilter.maxPages * 100) sessions in this view. Pick a status or search to reach the rest."
            : "The transcript search stopped before reading every session. Narrow the search, or pick a status, to cover the rest."
    }

    private var selectionLabel: String {
        selection.isEmpty ? "Select sessions" : "\(selection.count) selected"
    }

    private var searchableList: some View {
        list
            // The web UI's prompt box, at the foot of the board where a thumb reaches it.
            // Inside the searchable scope, so the bar knows when the search box has the
            // keyboard and steps aside.
            .safeAreaInset(edge: .bottom) { QuickRouterBar(editing: editMode.isEditing) }
            .searchable(text: $model.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search sessions...")
            .searchScopes($model.searchScope) { scopeTabs }
            // Debounced: a refresh per keystroke would be a request per keystroke.
            .task(id: SearchKey(text: model.searchText, scope: model.searchScope)) { await search() }
            .refreshable { await model.refresh() }
            .overlay {
                if model.isLoading && model.sessions.isEmpty { LoadingState(text: "Loading sessions…") }
            }
            .overlay(alignment: .bottom) { Toast(text: $model.notice) }
    }

    private func search() async {
        let key = SearchKey(text: model.searchText, scope: model.searchScope)
        guard key != appliedSearch else { return }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        appliedSearch = key
        await model.refresh()
    }

    @ViewBuilder
    private var scopeTabs: some View {
        Text(SearchScope.titles.label).tag(SearchScope.titles)
        Text(SearchScope.transcripts.label).tag(SearchScope.transcripts)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if editMode.isEditing {
                Button("Done") {
                    selection = []
                    reordering = false
                    editMode = .inactive
                }
                .accessibilityIdentifier("select.done")
            } else {
                Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier("settings.open")
            }
        }
        ToolbarItemGroup(placement: .bottomBar) {
            if isSelecting {
                Text(selectionLabel)
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSoft)
                Spacer()
                Button(role: .destructive) { confirmingBulkTrash = true } label: {
                    Label("Trash", systemImage: "trash")
                }
                .disabled(selection.isEmpty)
                .accessibilityIdentifier("select.trash")
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Picker("View", selection: $model.view) {
                    ForEach(BoardView.allCases) { view in Text(view.label).tag(view) }
                }
                Picker("Board visibility", selection: boardSelection) {
                    ForEach(BoardFilter.allCases) { board in Text(board.label).tag(board) }
                }
                Section {
                    Button {
                        reordering = false
                        editMode = .active
                    } label: {
                        Label("Select Sessions", systemImage: "checkmark.circle")
                    }
                    if model.view == .ranked {
                        Button {
                            reordering = true
                            editMode = .active
                        } label: {
                            Label("Reorder Spot Queue", systemImage: "arrow.up.arrow.down")
                        }
                        .accessibilityIdentifier("ranked.reorder")
                    }
                    Button {
                        confirmingRefreshAll = true
                    } label: {
                        Label("Refresh All", systemImage: "arrow.clockwise")
                    }
                }
            } label: {
                Image(systemName: model.board == .onBoard ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .accessibilityLabel("View options")
            .accessibilityIdentifier("board.menu")
            // The full form. The Quick Router is the bar at the foot of the screen.
            Button { model.showingNewSession = true } label: { Image(systemName: "square.and.pencil") }
                .accessibilityLabel("New session")
                .accessibilityIdentifier("newsession.open")
        }
    }

    private var isSnoozing: Binding<Bool> {
        Binding(get: { snoozing != nil }, set: { if !$0 { snoozing = nil } })
    }

    private var isTrashing: Binding<Bool> {
        Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } })
    }

    private var boardSelection: Binding<BoardFilter> {
        Binding(get: { model.board }, set: { board in Task { await model.select(board) } })
    }
}

/// One row with the web UI card's quick actions on its swipes and its long press.
private struct SwipeableSessionRow: View {
    @EnvironmentObject private var model: AppModel
    let session: SessionSummary
    @Binding var snoozing: SessionSummary?
    @Binding var trashing: SessionSummary?

    var body: some View {
        NavigationLink(value: session.id) {
            SessionRow(session: session, showsSummary: model.view == .yourBoard)
        }
        // Rows share one surface with hairlines between them, as the web UI's Your board and
        // Ranked views draw theirs: a card per row spent a third of the screen on margins.
        .themeRows()
        // 20 leading, where the section headers' text sits, so titles line up under them.
        .listRowInsets(EdgeInsets(top: 9, leading: 20, bottom: 9, trailing: 10))
        .accessibilityIdentifier("session.row.\(session.id)")
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                Task { await model.perform(session.isFavorite ? "Removed from favorites" : "Added to favorites", on: session.id) { try await $0.toggleFavorite(session.id) } }
            } label: {
                Label(session.isFavorite ? "Unfavorite" : "Favorite", systemImage: session.isFavorite ? "star.slash" : "star.fill")
            }
            .tint(Theme.Swipe.favorite)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if session.status == .archived {
                Button {
                    Task { await model.perform("Restored from trash", on: session.id) { try await $0.unarchive(session.id) } }
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
                .tint(Theme.Swipe.restore)
            } else {
                // Not `role: .destructive`: that animates the row away on the tap, before
                // the confirmation has been answered.
                Button { trashing = session } label: {
                    Label("Trash", systemImage: "trash")
                }
                .tint(Theme.Swipe.trash)
            }
            if session.boardVisibility == .visible {
                Button { snoozing = session } label: {
                    Label("Snooze", systemImage: "moon.zzz")
                }
                .tint(Theme.Swipe.snooze)
            } else {
                Button {
                    Task { await model.perform("Back on the board", on: session.id) { try await $0.setVisibility(session.id, .visible) } }
                } label: {
                    Label("Put back", systemImage: "eye")
                }
                .tint(Theme.Swipe.snooze)
            }
        }
        .contextMenu { SessionContextMenu(session: session, trashing: $trashing) }
    }
}

private struct SearchKey: Hashable {
    let text: String
    let scope: SearchScope
}

/// The snooze presets, for a dialog or a menu.
struct SnoozeButtons: View {
    @EnvironmentObject private var model: AppModel
    let session: SessionSummary

    var body: some View {
        ForEach(VisibilityChange.snoozePresets()) { preset in
            Button(preset.label) {
                let until = preset.until.formatted(date: .abbreviated, time: .shortened)
                Task { await model.perform("Snoozed until \(until)", on: session.id) { try await $0.setVisibility(session.id, .snoozed(until: preset.until)) } }
            }
        }
        Button("Hide") {
            Task { await model.perform("Hidden", on: session.id) { try await $0.setVisibility(session.id, .hidden) } }
        }
    }
}

/// Press and hold a row: the web UI card's actions.
private struct SessionContextMenu: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL
    let session: SessionSummary
    @Binding var trashing: SessionSummary?

    var body: some View {
        Button {
            Task { await model.perform(session.isFavorite ? "Removed from favorites" : "Added to favorites", on: session.id) { try await $0.toggleFavorite(session.id) } }
        } label: {
            Label(session.isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: session.isFavorite ? "star.slash" : "star")
        }
        if session.boardVisibility == .visible {
            Menu {
                SnoozeButtons(session: session)
            } label: {
                Label("Snooze until…", systemImage: "moon.zzz")
            }
        } else {
            Button {
                Task { await model.perform("Back on the board", on: session.id) { try await $0.setVisibility(session.id, .visible) } }
            } label: {
                Label("Put back on the board", systemImage: "eye")
            }
        }
        if let pr = session.pullRequests.last {
            Button { openURL(pr.url) } label: { Label("View PR \(pr.label)", systemImage: "arrow.triangle.pull") }
        }
        if let url = model.webURL(for: session.id) {
            Button { openURL(url) } label: { Label("Open in browser", systemImage: "safari") }
        }
        Divider()
        if session.status == .running {
            Button {
                Task { await model.perform("Paused", on: session.id) { try await $0.pause(session.id) } }
            } label: {
                Label("Pause Session", systemImage: "pause.circle")
            }
        }
        if session.status == .waiting {
            Button {
                Task { await model.startNow(session.id) }
            } label: {
                Label("Start Now", systemImage: "play.circle")
            }
        }
        if session.status == .failed || session.status == .needsInput {
            Button {
                Task { await model.perform("Restarted", on: session.id) { try await $0.restart(session.id) } }
            } label: {
                Label("Restart Session", systemImage: "arrow.clockwise.circle")
            }
        }
        if session.status == .archived {
            Button {
                Task { await model.perform("Restored from trash", on: session.id) { try await $0.unarchive(session.id) } }
            } label: {
                Label("Restore from Trash", systemImage: "arrow.uturn.backward")
            }
        } else {
            Button(role: .destructive) { trashing = session } label: { Label("Trash", systemImage: "trash") }
        }
    }
}

private struct FilterBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    // The web UI's filter form, behind one button: every filter, combinable.
                    Button {
                        Haptics.selection()
                        model.showingFilters = true
                    } label: {
                        Pill(selected: model.effectiveFilters.preset == nil, compact: true) {
                            Label(filtersLabel, systemImage: "line.3.horizontal.decrease")
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Filters")
                    .accessibilityValue(model.filterSummary)
                    .accessibilityIdentifier("filter.more")
                    ForEach(SessionFilter.allCases) { filter in
                        let selected = model.effectiveFilters.preset == filter
                        Button {
                            Haptics.selection()
                            Task { await model.select(filter) }
                        } label: {
                            Pill(selected: selected, compact: true) { Text(filter.label) }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("filter.\(filter.rawValue)")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.vertical, 2)
                .animation(.snappy(duration: 0.25), value: model.filters)
            }
            // A combination the chips cannot show is said in words, with a way back.
            if model.effectiveFilters.preset == nil {
                HStack(spacing: 6) {
                    Text(model.filterSummary)
                        .font(.caption)
                        .foregroundStyle(Theme.inkSoft)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityIdentifier("filter.summary")
                    Button("Reset") { Task { await model.apply(.default) } }
                        // Borderless, or the whole list row becomes this button's target.
                        .buttonStyle(.borderless)
                        .font(.caption.weight(.medium))
                        .accessibilityIdentifier("filter.reset")
                        .fixedSize()
                }
                // Bounded and leading, so a long summary truncates at its end rather than
                // pushing the row wider and losing its first letters off the edge.
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(isPresented: $model.showingFilters) { BoardFiltersSheet(initial: model.filters) }
    }

    private var filtersLabel: String {
        guard model.filters.preset == nil else { return "Filters" }
        let count = model.filters.refinementCount + (model.filters.statuses.count > 1 ? 1 : 0)
        return count > 0 ? "Filters · \(count)" : "Filters"
    }
}

/// One row of the web UI's board: the title on two lines at most, then one line of what the
/// card carries — the status pill, Priority, `#id`, a compact age, the latest PR, a notes
/// mark — and a star when it is a favourite. A trashed session reads in the quieter ink, as
/// Motet dims what is done, so the ones waiting on you stand out without a heavier face.
struct SessionRow: View {
    let session: SessionSummary
    /// Your board's rows carry the session's "where things stand", as the web UI's do.
    var showsSummary = false

    var body: some View {
        let quiet = session.status == .archived
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(session.displayTitle)
                    .font(.system(.subheadline, weight: session.status == .needsInput ? .semibold : .medium))
                    .foregroundStyle(quiet ? Theme.inkSoft : Theme.ink)
                    .lineLimit(2)
                Spacer(minLength: 4)
                if session.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(Theme.gold)
                        .accessibilityLabel("Favorite")
                }
            }
            HStack(spacing: 5) {
                StatusBadge(status: session.status, compact: true)
                if session.isPriority {
                    Text("Priority")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.danger)
                }
                // Verbatim: a session id is an identifier, not a quantity to group. Monospaced,
                // as the web UI's `font-mono` ids are.
                Text(verbatim: "#\(session.id)")
                    .font(Theme.mono)
                    .foregroundStyle(Theme.inkMute)
                if let date = session.updatedAt ?? session.createdAt {
                    Text("·").foregroundStyle(Theme.inkMute)
                    // Compact on screen; VoiceOver still hears "41 minutes ago".
                    Text(verbatim: Format.age(date))
                        .accessibilityLabel(date.formatted(.relative(presentation: .named)))
                }
                if let pr = session.pullRequests.last {
                    Text("·").foregroundStyle(Theme.inkMute)
                    Image(systemName: PullRequestChip.symbol(for: pr.state))
                        .foregroundStyle(PullRequestChip.color(for: pr.state))
                    Text(pr.label)
                    if pr.state == "open", let ci = pr.ci {
                        Circle().fill(PullRequestChip.ciColor(ci)).frame(width: 6, height: 6)
                            .accessibilityLabel("CI \(ci)")
                    }
                }
                if session.hasNotes {
                    Image(systemName: "note.text").accessibilityLabel("Has notes")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Theme.inkSoft)
            .lineLimit(1)
            if session.boardVisibility != .visible {
                VisibilityLabel(session: session)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.snooze)
            }
            if showsSummary {
                RowSummary(session: session)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Your board's summary under a row, as the web UI draws it: the cached "where things stand"
/// as inline markdown on three lines at most, then how current it is, and the agent root.
private struct RowSummary: View {
    let session: SessionSummary

    var body: some View {
        let summary = session.boardRow?.statusSummary
        VStack(alignment: .leading, spacing: 3) {
            if let summary, let text = summary.summary, !text.isEmpty {
                Text(Self.inline(text))
                    .font(.caption)
                    .foregroundStyle(Theme.inkSoft)
                    .tint(Theme.accent)
                    .lineLimit(3)
                    .accessibilityIdentifier("row.summary.\(session.id)")
            } else {
                Text("No status summary yet.")
                    .font(.caption.italic())
                    .foregroundStyle(Theme.inkMute)
            }
            HStack(spacing: 5) {
                if let summary, summary.summary?.isEmpty == false {
                    let freshness = SummaryFreshness(summary)
                    HStack(spacing: 3) {
                        Circle().fill(Self.color(freshness)).frame(width: 5, height: 5)
                        Text(freshness.label).foregroundStyle(Self.color(freshness))
                    }
                    if case let .stale(messages) = freshness {
                        Text(messages == 1 ? "1 message since" : "\(messages) messages since")
                    }
                    if let written = summary.generatedAt {
                        let age = Format.age(written)
                        Text(verbatim: age == "now" ? "written just now" : "written \(age) ago")
                    }
                }
                if let root = session.agentRoot {
                    Text(verbatim: root)
                        .font(Theme.mono)
                        .foregroundStyle(Theme.inkMute)
                }
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(Theme.inkMute)
            .lineLimit(1)
        }
        .padding(.top, 1)
    }

    /// Inline only, as the web UI renders it on a row: a paragraph break would push the
    /// row around.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    static func color(_ freshness: SummaryFreshness) -> Color {
        switch freshness {
        case .regenerating: return Theme.accent
        case .stale: return Theme.warning
        case .current: return Theme.success
        }
    }
}

private struct EmptyListRow: View {
    let filters: BoardFilters
    let searching: Bool

    var body: some View {
        EmptyState(
            title: message,
            symbol: searching ? "magnifyingglass" : (filters.preset == .needsInput ? "checkmark" : "tray"),
            message: detail
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sessions.empty")
    }

    private var message: String {
        if searching { return "No sessions match." }
        switch filters.preset {
        case .needsInput: return "Nothing needs you right now."
        case .some(let preset): return "No \(preset.label.lowercased()) sessions."
        case .none: return "No sessions match these filters."
        }
    }

    private var detail: String? {
        if searching { return "Try other words, or search transcripts." }
        switch filters.preset {
        case .needsInput: return "Sessions waiting on you land here."
        case .some: return nil
        case .none: return filters.summary
        }
    }
}

/// The web UI's toast: one line at the bottom that goes away on its own.
struct Toast: View {
    @Binding var text: String?
    var identifier = "toast"

    var body: some View {
        if let text {
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.rule, lineWidth: 1))
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityIdentifier(identifier)
                .allowsHitTesting(false)
                .task(id: text) {
                    try? await Task.sleep(for: .seconds(2.5))
                    guard !Task.isCancelled else { return }
                    withAnimation { self.text = nil }
                }
        }
    }
}
