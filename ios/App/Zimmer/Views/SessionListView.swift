import SwiftUI
import ZimmerKit

/// Sessions, in one of the web UI's four board views, filtered by status and by board
/// visibility as the web UI's board is. "Needs input" is the default filter and the first
/// chip: the phone is for the sessions waiting on a person. Swipe right to star, left to
/// trash or snooze; press and hold for everything else the web UI's card offers; Select to
/// trash several at once.
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
                Button("Refresh All") { Task { await model.refreshAll() } }
            } message: {
                Text("Re-reads every transcript, and restarts failed sessions and ones an interruption left waiting on you. Sessions you paused stay paused.")
            }
            .environment(\.editMode, $editMode)
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .sheet(isPresented: $model.showingQuickRouter) { QuickRouterView() }
    }

    private var list: some View {
        List(selection: $selection) {
            Section {
                FilterBar()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            } footer: {
                if model.board != .onBoard {
                    Label("Showing: \(model.board.label)", systemImage: "eye")
                        .accessibilityIdentifier("board.current")
                }
            }
            if let error = model.error {
                Section { ErrorBanner(error: error).listRowInsets(EdgeInsets()) }
            }
            if model.sessions.isEmpty && !model.isLoading {
                Section { EmptyListRow(filter: model.filter, searching: !model.searchText.isEmpty) }
            }
            ForEach(model.sections) { section in
                Section {
                    ForEach(section.sessions) { session in
                        SwipeableSessionRow(session: session, snoozing: $snoozing, trashing: $trashing)
                    }
                } header: {
                    if let title = section.title {
                        Text(title).accessibilityIdentifier("section.\(title)")
                    }
                }
            }
            if model.searchIncomplete && !model.searchText.isEmpty {
                Section {} footer: {
                    Text("The transcript search stopped before reading every session. Narrow the search, or pick a status, to cover the rest.")
                        .accessibilityIdentifier("search.incomplete")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Sessions")
        .navigationBarTitleDisplayMode(.large)
    }

    private var isSelecting: Bool { editMode.isEditing }

    private var searchableList: some View {
        list
            .searchable(text: $model.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search sessions...")
            .searchScopes($model.searchScope) { scopeTabs }
            // Debounced: a refresh per keystroke would be a request per keystroke.
            .task(id: SearchKey(text: model.searchText, scope: model.searchScope)) { await search() }
            .refreshable { await model.refresh() }
            .overlay {
                if model.isLoading && model.sessions.isEmpty { ProgressView() }
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
            if isSelecting {
                Button("Done") {
                    selection = []
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
                Text(selection.isEmpty ? "Select sessions" : "\(selection.count) selected")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                        editMode = .active
                    } label: {
                        Label("Select Sessions", systemImage: "checkmark.circle")
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
            Button { model.showingQuickRouter = true } label: { Image(systemName: "square.and.pencil") }
                .accessibilityLabel("New session")
                .accessibilityIdentifier("quickrouter.open")
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
            SessionRow(session: session)
        }
        .accessibilityIdentifier("session.row.\(session.id)")
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                Task { await model.perform(session.isFavorite ? "Removed from favorites" : "Added to favorites", on: session.id) { try await $0.toggleFavorite(session.id) } }
            } label: {
                Label(session.isFavorite ? "Unfavorite" : "Favorite", systemImage: session.isFavorite ? "star.slash" : "star.fill")
            }
            .tint(.yellow)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if session.status == .archived {
                Button {
                    Task { await model.perform("Restored from trash", on: session.id) { try await $0.unarchive(session.id) } }
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
                .tint(.green)
            } else {
                // Not `role: .destructive`: that animates the row away on the tap, before
                // the confirmation has been answered.
                Button { trashing = session } label: {
                    Label("Trash", systemImage: "trash")
                }
                .tint(.red)
            }
            if session.boardVisibility == .visible {
                Button { snoozing = session } label: {
                    Label("Snooze", systemImage: "moon.zzz")
                }
                .tint(.indigo)
            } else {
                Button {
                    Task { await model.perform("Back on the board", on: session.id) { try await $0.setVisibility(session.id, .visible) } }
                } label: {
                    Label("Put back", systemImage: "eye")
                }
                .tint(.indigo)
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SessionFilter.allCases) { filter in
                    let selected = filter == model.filter
                    Button {
                        Haptics.selection()
                        Task { await model.select(filter) }
                    } label: {
                        Text(filter.label)
                            .font(.subheadline.weight(selected ? .semibold : .regular))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(selected ? Color.accentColor : Color(.secondarySystemBackground), in: Capsule())
                            .foregroundStyle(selected ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("filter.\(filter.rawValue)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// One card of the web UI's board, as a row: title, the status pill, `#id`, when it last
/// moved, and the markers the card carries — a star, a PR, notes, a snooze.
struct SessionRow: View {
    let session: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(session.displayTitle)
                    .font(.body.weight(session.status == .needsInput ? .semibold : .regular))
                    .lineLimit(2)
                Spacer(minLength: 4)
                if session.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .accessibilityLabel("Favorite")
                }
            }
            HStack(spacing: 6) {
                StatusBadge(status: session.status, compact: true)
                if session.isPriority {
                    Text("Priority").foregroundStyle(.red)
                }
                // Verbatim: a session id is an identifier, not a quantity to group.
                Text(verbatim: "#\(session.id)")
                if let date = session.updatedAt ?? session.createdAt {
                    Text("·")
                    Text(date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                }
                if let pr = session.pullRequests.last {
                    Text("·")
                    Image(systemName: PullRequestChip.symbol(for: pr.state))
                        .foregroundStyle(PullRequestChip.color(for: pr.state))
                    Text(pr.label)
                }
                if session.hasNotes {
                    Image(systemName: "note.text").accessibilityLabel("Has notes")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            if session.boardVisibility != .visible {
                VisibilityLabel(session: session)
                    .font(.caption)
                    .foregroundStyle(.indigo)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct EmptyListRow: View {
    let filter: SessionFilter
    let searching: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: searching ? "magnifyingglass" : (filter == .needsInput ? "checkmark.circle" : "tray"))
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(message)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .accessibilityIdentifier("sessions.empty")
    }

    private var message: String {
        if searching { return "No sessions match." }
        return filter == .needsInput ? "Nothing needs you right now." : "No \(filter.label.lowercased()) sessions."
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
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: Capsule())
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
