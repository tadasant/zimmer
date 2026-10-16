import SwiftUI
import ZimmerKit

/// Sessions, in one of the web UI's four board views, filtered by status and by board
/// visibility as the web UI's board is. "Needs input" is the default filter and the first
/// chip: the phone is for the sessions waiting on a person. Swipe right to star, left to
/// trash or snooze; press and hold for everything else the web UI's card and its row menu
/// offer; Select to trash several at once. The Quick Router bar is pinned to the foot: the
/// board is where work starts.
struct SessionListView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingSettings = false
    @State private var snoozing: SessionSummary?
    /// A row whose PR is about to be authorized to merge, waiting on the confirmation.
    @State private var merging: SessionSummary?
    @State private var confirmingReprioritize = false
    /// A row's *Custom…* snooze, open in its sheet.
    @State private var customSnoozing: SessionSummary?
    @State private var renaming: SessionSummary?
    @State private var newTitle = ""
    /// A restart that takes over a session waiting on you, waiting on its confirmation.
    @State private var restarting: SessionSummary?
    /// The search the list last loaded, so appearing does not reload a list `start()` just loaded.
    @State private var appliedSearch = SearchKey(text: "", scope: .titles)
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<Int>()
    @State private var confirmingBulkTrash = false
    @State private var confirmingRefreshAll = false
    /// The Ranked view's drag-and-drop, as an edit mode of its own: handles on the spot queue.
    @State private var reordering = false

    var body: some View {
        listWithDecisions
            .toolbar { toolbarContent }
            .confirmationDialog(
                "Snooze until…", isPresented: isSnoozing,
                titleVisibility: .visible, presenting: snoozing
            ) { session in
                SnoozeButtons(session: session) { customSnoozing = session }
            } message: { _ in
                Text("Visual only — it does not pause, start or stop the session.")
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
            // A refresh while rows are selected or being dragged would move them under a finger.
            // Select and Reorder only, not the `transient` mode SwiftUI's docs say it may
            // engage during a swipe: a swipe must never leave the board unable to read.
            .onChange(of: isSelectingOrReordering) { _, editing in model.isEditingBoard = editing }
            // Selecting hides the tab bar, as Mail does: the Trash bar takes its place at the bottom.
            .toolbar(editMode.isEditing ? .hidden : .visible, for: .tabBar)
            // A selection only ever names rows on screen: a filter, search or view change drops the rest.
            .onChange(of: model.sessions.map(\.id)) { _, ids in selection.formIntersection(ids) }
            // The server orders each view, so a new view is a new list.
            .onChange(of: model.view) { _, view in
                if reordering { reordering = false; editMode = .inactive }
                Task { await model.viewChanged() }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .modifier(QueuedTrashQuestion { _ in model.path.isEmpty })
    }

    /// The questions a row's own actions ask: a custom snooze time, a new title, and whether a
    /// restart may take a session over.
    private var promptingList: some View {
        searchableList
            .sheet(item: $customSnoozing) { session in
                CustomSnoozeSheet { until in
                    let label = until.formatted(date: .abbreviated, time: .shortened)
                    return await model.perform("Snoozed until \(label)", on: session.id) { try await $0.setVisibility(session.id, .snoozed(until: until)) }
                }
            }
            .alert("Rename session", isPresented: isRenaming, presenting: renaming) { session in
                TextField("Title", text: $newTitle)
                    .accessibilityIdentifier("rename.field")
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { await model.perform("Renamed", on: session.id) { try await $0.rename(session.id, title: title) } }
                }
                .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .confirmationDialog(
                "Restart this session?", isPresented: isRestarting,
                titleVisibility: .visible, presenting: restarting
            ) { session in
                Button("Restart") {
                    Task { await model.perform("Restarted", on: session.id) { try await $0.restart(session.id) } }
                }
            } message: { session in
                // The web UI's own confirm text for this session's restart.
                Text(session.restartConfirmation(transcriptPresent: nil) ?? "")
            }
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
                VStack(alignment: .leading, spacing: 6) {
                    // In the footer, not the row: a row with no insets clips text at its leading
                    // edge, which the chips escape only because they scroll.
                    FilterSummary()
                    if model.board != .onBoard {
                        Label("Showing: \(model.board.label)", systemImage: "eye")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Theme.snooze)
                            .accessibilityIdentifier("board.current")
                    }
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
                        SwipeableSessionRow(session: session, snoozing: $snoozing, prompts: rowPrompts)
                            // Only spot rows move: the server places a drop by its spot neighbours,
                            // and a priority row has none, so a drag would reset its precedence.
                            .moveDisabled(session.isPriority)
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

    /// Select or Reorder, as the board's poller has to know: `.active` only.
    private var isSelectingOrReordering: Bool { editMode == .active }

    /// Drag handles while reordering: on Your board, its spot rows; on Ranked, the spot queue.
    private func moveHandler(for section: BoardSection) -> ((IndexSet, Int) -> Void)? {
        guard reordering, model.view == .yourBoard || section.title == "Spot queue" else { return nil }
        return { source, destination in drop(section.sessions, from: source, to: destination) }
    }

    /// A drop: the server is told the rows of the same class it landed between and works out
    /// the precedence, as the web UI's Your board and Ranked views do.
    private func drop(_ rows: [SessionSummary], from source: IndexSet, to destination: Int) {
        var moved = rows
        moved.move(fromOffsets: source, toOffset: destination)
        guard let from = source.first, let index = moved.firstIndex(where: { $0.id == rows[from].id }) else { return }
        let (above, below) = BoardView.dropNeighbours(moved, at: index)
        Task { await model.reorder(moved[index].id, above: above, below: below) }
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
            // A scroll of the board puts the bar's keyboard away: the bar sits on the keyboard,
            // so a drag that has to reach the keyboard (`.interactively`) would rarely get there.
            .scrollDismissesKeyboard(.immediately)
            // Above the Quick Router bar rather than over it: the Undo toast takes taps.
            .overlay(alignment: .bottom) {
                VStack(spacing: 0) {
                    UndoToast(session: $model.undoable) { Task { await model.undoTrash() } }
                    Toast(text: $model.notice)
                }
            }
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
                    if model.view == .yourBoard || model.view == .ranked {
                        Button {
                            confirmingReprioritize = true
                        } label: {
                            Label("Reprioritize", systemImage: "list.number")
                        }
                    }
                    if model.view.isReorderable {
                        Button {
                            reordering = true
                            editMode = .active
                        } label: {
                            Label(model.view == .ranked ? "Reorder Spot Queue" : "Reorder Board", systemImage: "arrow.up.arrow.down")
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
            // Live Mode and Live Voice: one continuous conversation with Zimmer.
            Button { model.showingLive = true } label: { Image(systemName: "waveform") }
                .accessibilityLabel("Live")
                .accessibilityIdentifier("live.open")
            // The full form. The Quick Router is the bar at the foot of the screen.
            Button { model.showingNewSession = true } label: { Image(systemName: "square.and.pencil") }
                .accessibilityLabel("New session")
                .accessibilityIdentifier("newsession.open")
        }
    }

    private var isSnoozing: Binding<Bool> {
        Binding(get: { snoozing != nil }, set: { if !$0 { snoozing = nil } })
    }

    /// The prompting list with Merge's and Reprioritize's confirmations: a separate expression,
    /// because one modifier chain holding every dialog is more than the type checker will take.
    private var listWithDecisions: some View {
        promptingList
            .confirmationDialog(
                "Authorize the merge?", isPresented: isMerging,
                titleVisibility: .visible, presenting: merging
            ) { session in
                Button("Merge \(session.mergeablePullRequest?.label ?? "PR")") {
                    Task { await model.authorizeMerge(session.id) }
                }
            } message: { session in
                Text("Session #\(session.id) is told to check for conflicts, merge \(session.mergeablePullRequest?.label ?? "its PR"), and archive itself. Your tap is the sign-off.")
            }
            .confirmationDialog("Reprioritize the board?", isPresented: $confirmingReprioritize, titleVisibility: .visible) {
                Button("Reprioritize") { Task { await model.reprioritize() } }
            } message: {
                Text("Zimmer's reprioritizing session re-ranks this board and writes the order back. You can still drag anything afterwards.")
            }
    }

    private var isMerging: Binding<Bool> {
        Binding(get: { merging != nil }, set: { if !$0 { merging = nil } })
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var isRestarting: Binding<Bool> {
        Binding(get: { restarting != nil }, set: { if !$0 { restarting = nil } })
    }

    /// What a row's long press opens on this screen.
    private var rowPrompts: RowPrompts {
        RowPrompts(
            customSnooze: { customSnoozing = $0 },
            rename: { session in
                newTitle = session.title ?? ""
                renaming = session
            },
            merge: { merging = $0 },
            restart: { session in
                // A failed session restarts at once; one waiting on you is taken over, so the
                // web UI asks first.
                // The board does not know whether a transcript is stored; the session page does.
                if session.restartConfirmation(transcriptPresent: nil) != nil {
                    restarting = session
                } else {
                    Task { await model.perform("Restarted", on: session.id) { try await $0.restart(session.id) } }
                }
            }
        )
    }

    private var boardSelection: Binding<BoardFilter> {
        Binding(get: { model.board }, set: { board in Task { await model.select(board) } })
    }
}

/// The questions a row's long press hands back to the list to ask.
private struct RowPrompts {
    let customSnooze: (SessionSummary) -> Void
    let rename: (SessionSummary) -> Void
    let merge: (SessionSummary) -> Void
    let restart: (SessionSummary) -> Void
}

/// One row with the web UI card's quick actions on its swipes and its long press.
private struct SwipeableSessionRow: View {
    @EnvironmentObject private var model: AppModel
    let session: SessionSummary
    @Binding var snoozing: SessionSummary?
    let prompts: RowPrompts

    var body: some View {
        NavigationLink(value: session.id) {
            SessionRow(session: session, showsSummary: model.view == .yourBoard && session.boardRow != nil)
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
            // The web UI's row Merge button: offered only on an open, green PR.
            if session.mergeablePullRequest != nil {
                Button { prompts.merge(session) } label: {
                    Label("Merge", systemImage: "arrow.triangle.merge")
                }
                // The web Merge button's green-600.
                .tint(Theme.Swipe.restore)
            }
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
                // the server has answered (and it may ask about queued messages first).
                Button { Task { await model.trash(session) } } label: {
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
        .contextMenu { SessionContextMenu(session: session, prompts: prompts) }
    }
}

private struct SearchKey: Hashable {
    let text: String
    let scope: SearchScope
}

/// The snooze presets, then a time of your own, then Hide — the web UI's snooze menu, for a
/// dialog or a menu. `custom` opens the picker.
struct SnoozeButtons: View {
    @EnvironmentObject private var model: AppModel
    let session: SessionSummary
    let custom: () -> Void

    var body: some View {
        ForEach(VisibilityChange.snoozePresets()) { preset in
            Button(preset.label) {
                let until = preset.until.formatted(date: .abbreviated, time: .shortened)
                Task { await model.perform("Snoozed until \(until)", on: session.id) { try await $0.setVisibility(session.id, .snoozed(until: preset.until)) } }
            }
        }
        Button("Custom…", action: custom)
        Button("Hide") {
            Task { await model.perform("Hidden", on: session.id) { try await $0.setVisibility(session.id, .hidden) } }
        }
    }
}

/// Press and hold a row: the web UI card's actions, with the rename its title's pencil
/// offers and the refresh beside its status pill.
private struct SessionContextMenu: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL
    let session: SessionSummary
    let prompts: RowPrompts

    var body: some View {
        if let pr = session.mergeablePullRequest {
            Button { prompts.merge(session) } label: {
                Label("Merge \(pr.label)", systemImage: "arrow.triangle.merge")
            }
        }
        Button {
            Task { await model.perform(session.isFavorite ? "Removed from favorites" : "Added to favorites", on: session.id) { try await $0.toggleFavorite(session.id) } }
        } label: {
            Label(session.isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: session.isFavorite ? "star.slash" : "star")
        }
        if session.boardVisibility == .visible {
            Menu {
                SnoozeButtons(session: session) { prompts.customSnooze(session) }
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
        // Every PR, as the session menu lists them: the row's line has room for the newest only.
        if session.pullRequests.count == 1, let pr = session.pullRequests.first {
            Button { openURL(pr.url) } label: { Label("View PR \(pr.label)", systemImage: "arrow.triangle.pull") }
        } else if !session.pullRequests.isEmpty {
            Menu {
                ForEach(session.pullRequests.reversed()) { pr in
                    Button("\(pr.label) (\(pr.state?.capitalized ?? "Unknown"))") { openURL(pr.url) }
                }
            } label: {
                Label("View PR (\(session.pullRequests.count))", systemImage: "arrow.triangle.pull")
            }
        }
        // The web card's heart, on the views that draw cards.
        if model.view == .lastTouched || model.view == .created, session.status != .archived {
            let enabled = session.heartbeatEnabled ?? false
            Button {
                Task { await model.perform(enabled ? "Heartbeat off" : "Heartbeat on", on: session.id) { try await $0.setHeartbeat(session.id, enabled: !enabled) } }
            } label: {
                Label(enabled ? "Turn Heartbeat Off" : "Turn Heartbeat On", systemImage: enabled ? "heart.slash" : "heart")
            }
        }
        if let url = model.webURL(for: session.id) {
            Button { openURL(url) } label: { Label("Open in browser", systemImage: "safari") }
        }
        Button { prompts.rename(session) } label: { Label("Rename", systemImage: "pencil") }
        // The card hides its refresh on a running session: it is live already.
        if session.status != .running {
            Button {
                Task { await model.run { try await $0.refreshTranscript(session.id) } }
            } label: {
                Label("Refresh Transcript", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        Divider()
        // The Ranked row's ⋮: a promotion starts a waiting session; a demotion lands at the
        // head of the spot queue.
        if model.view == .ranked, session.status != .archived {
            Button {
                Task { await model.reschedule(session.id, priority: !session.isPriority) }
            } label: {
                Label(session.isPriority ? "Demote to Spot" : "Promote to Priority",
                      systemImage: session.isPriority ? "arrow.down.to.line" : "arrow.up.to.line")
            }
        }
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
            Button { prompts.restart(session) } label: {
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
            Button(role: .destructive) { Task { await model.trash(session) } } label: { Label("Trash", systemImage: "trash") }
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
        }
        .sheet(isPresented: $model.showingFilters) { BoardFiltersSheet(initial: model.filters) }
    }

    private var filtersLabel: String {
        guard model.filters.preset == nil else { return "Filters" }
        let count = model.filters.refinementCount + (model.filters.statuses.count > 1 ? 1 : 0)
        return count > 0 ? "Filters · \(count)" : "Filters"
    }
}

/// A combination the chips cannot show, said in words, with a way back.
private struct FilterSummary: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.effectiveFilters.preset == nil {
            HStack(spacing: 6) {
                Text(model.filterSummary)
                    .font(.caption)
                    .foregroundStyle(Theme.inkSoft)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("filter.summary")
                Button("Reset") { Task { await model.apply(.default) } }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.medium))
                    .accessibilityIdentifier("filter.reset")
                    .fixedSize()
            }
        }
    }
}

/// One row of the web UI's board: the title on two lines at most, then one line of what the
/// card carries — the status pill, Priority, `#id`, a compact age, the latest PR, a notes
/// mark — then the web rows' facts line — the agent root, the genesis, the precedence, the
/// heart when the heartbeat is on — and a star when it is a favourite. A trashed session
/// reads in the quieter ink, as Motet dims what is done, so the ones waiting on you stand out
/// without a heavier face.
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
            RowFacts(session: session)
            if session.boardVisibility != .visible {
                VisibilityLabel(session: session)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.snooze)
            }
            if session.status == .archived {
                TrashExpiryLabel(session: session)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.inkMute)
            }
            if showsSummary {
                RowSummary(session: session)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The web rows' facts, on one quiet line: the agent root (`_session_card`, `_user_view_row`,
/// `_ranked_row`), the genesis (the card's `genesis · class` pill; the class is the Priority
/// tag above), the precedence (`_user_view_row`'s `#N`, Ranked's rank) and the heart when the
/// heartbeat is on (the card's top-right heart). Nothing when there is nothing to say.
private struct RowFacts: View {
    let session: SessionSummary

    var body: some View {
        let rank = session.precedence
        let beating = session.heartbeatEnabled == true
        if session.agentRoot != nil || session.genesis != nil || rank != nil || beating {
            HStack(spacing: 5) {
                if let root = session.agentRoot {
                    Text(verbatim: root)
                        .font(Theme.mono)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityLabel("Agent root \(root)")
                }
                if let genesis = session.genesis {
                    if session.agentRoot != nil { Text("·") }
                    Text(verbatim: genesis)
                        .lineLimit(1)
                        .accessibilityLabel("Origin \(genesis)")
                }
                if let rank {
                    if session.agentRoot != nil || session.genesis != nil { Text("·") }
                    // The web's "Precedence — higher is worked sooner"; "rank", since `#` is the id.
                    Text(verbatim: "rank \(rank)")
                        .accessibilityLabel("Precedence \(rank)")
                }
                if beating {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(Theme.danger)
                        .accessibilityLabel("Heartbeat on")
                }
            }
            .font(.caption2.weight(.medium).monospacedDigit())
            .foregroundStyle(Theme.inkMute)
        }
    }
}

/// Your board's summary under a row, as the web UI draws it: the cached "where things stand"
/// as inline markdown on three lines at most, then how current it is. The agent root is on
/// the row's facts line, as on every view.
private struct RowSummary: View {
    let session: SessionSummary

    var body: some View {
        let summary = session.boardRow?.statusSummary
        VStack(alignment: .leading, spacing: 3) {
            if let summary, let text = summary.summary, !text.isEmpty {
                // Links read as text: the row is one tap target, and opens the session, whose
                // copy of the summary has working links.
                Text(MarkdownInline.attributed(text))
                    .font(.caption)
                    .foregroundStyle(Theme.inkSoft)
                    .tint(Theme.inkSoft)
                    .lineLimit(3)
            } else {
                Text("No status summary yet.")
                    .font(.caption.italic())
                    .foregroundStyle(Theme.inkMute)
            }
            if let summary, summary.summary?.isEmpty == false {
                let freshness = SummaryFreshness(summary)
                HStack(spacing: 5) {
                    HStack(spacing: 3) {
                        Circle().fill(Self.color(freshness)).frame(width: 5, height: 5)
                        Text(freshness.label).foregroundStyle(Self.color(freshness))
                    }
                    if let behind = summary.messagesSinceGenerated, behind > 0 {
                        Text(behind == 1 ? "1 message since" : "\(behind) messages since")
                    }
                    if let written = summary.generatedAt {
                        let age = Format.age(written)
                        Text(verbatim: age == "now" ? "written just now" : "written \(age) ago")
                    }
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(Theme.inkMute)
                .lineLimit(1)
            }
        }
        .padding(.top, 1)
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

/// The web UI's Undo toast after a trash: on screen for as long as the server would still
/// undo it, with the button that does.
struct UndoToast: View {
    @Binding var session: SessionSummary?
    let undo: () -> Void

    var body: some View {
        if let session {
            HStack(spacing: 14) {
                Text("Moved to trash")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.ink)
                Button("Undo", action: undo)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .accessibilityIdentifier("toast.undo")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.rule, lineWidth: 1))
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("toast")
            .task(id: session.id) {
                try? await Task.sleep(for: TrashOutcome.undoWindow)
                guard !Task.isCancelled else { return }
                withAnimation { self.session = nil }
            }
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

/// The web UI's *Archive anyway*: a trash refused because messages are queued for the
/// session, asked again naming the discard. Shown by the screen the trash came from — the
/// board, or that session's page — since a dialog on the navigation stack would stand over
/// the page's own dialogs and keep them from presenting.
struct QueuedTrashQuestion: ViewModifier {
    @EnvironmentObject private var app: AppModel
    /// Whether this screen is the one that asks about `session`.
    let asks: (SessionSummary) -> Bool

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Discard its queued messages?",
            isPresented: Binding(
                get: { app.queuedTrash.map(asks) ?? false },
                set: { if !$0 { app.queuedTrash = nil } }
            ),
            titleVisibility: .visible,
            presenting: app.queuedTrash
        ) { session in
            Button("Trash anyway", role: .destructive) {
                Task { await app.trash(session, force: true) }
            }
        } message: { _ in
            Text("Messages are waiting to be delivered to this session. Trashing it discards them.")
        }
    }
}
