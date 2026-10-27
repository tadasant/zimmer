import SwiftUI
import ZimmerKit

/// The web UI's filter form for the board, as a sheet: statuses (any number), scheduling
/// class, agent root, genesis and CarPlay fit, all combining, plus board visibility and the
/// quick filters.
/// Nothing changes until *Apply*, as the web form applies on submit.
struct BoardFiltersSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: BoardFilters
    @State private var board: BoardFilter = .onBoard

    init(initial: BoardFilters) {
        _draft = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    quick("All", .all, identifier: "filters.quick.all")
                    quick("All unarchived", .allUnarchived, identifier: "filters.quick.unarchived")
                    quick("All priority, unarchived", .allPriorityUnarchived, identifier: "filters.quick.priority")
                } header: {
                    Text("Quick filters")
                }

                Section {
                    ForEach(SessionStatus.allCases, id: \.rawValue) { status in
                        Toggle(status.label, isOn: Binding(
                            get: { draft.includes(status) },
                            set: { _ in draft.toggle(status) }
                        ))
                        .accessibilityIdentifier("filters.status.\(status.rawValue)")
                    }
                } header: {
                    Text("Status")
                } footer: {
                    Text("Tick any number. None ticked shows every status except Archived.")
                }

                Section {
                    Picker("Scheduling class", selection: $draft.schedulingClass) {
                        Text("Any").tag(String?.none)
                        Text("Priority").tag(String?.some("priority"))
                        Text("Spot").tag(String?.some("spot"))
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("filters.class")
                } header: {
                    Text("Scheduling class")
                }

                Section {
                    Picker("Agent root", selection: $draft.agentRoot) {
                        Text("Any").tag(String?.none)
                        ForEach(model.filterOptions?.agentRoots ?? []) { root in
                            Text(root.displayName ?? root.name).tag(String?.some(root.name))
                        }
                        // A remembered root the catalog no longer lists stays selectable.
                        if let root = draft.agentRoot, !(model.filterOptions?.agentRoots.contains { $0.name == root } ?? false) {
                            Text(root).tag(String?.some(root))
                        }
                    }
                    .accessibilityIdentifier("filters.root")
                    Picker("Genesis", selection: $draft.genesis) {
                        Text("Any").tag(String?.none)
                        ForEach(model.filterOptions?.geneses ?? []) { genesis in
                            Text(genesis.label).tag(String?.some(genesis.key))
                        }
                    }
                    .accessibilityIdentifier("filters.genesis")
                } header: {
                    Text("Advanced")
                }

                Section {
                    Picker("CarPlay fit", selection: $draft.carplayFitFilter) {
                        Text("Any").tag(CarplayFitFilter?.none)
                        ForEach(CarplayFitFilter.allCases) { filter in
                            Text(filter.label).tag(CarplayFitFilter?.some(filter))
                        }
                    }
                    .accessibilityIdentifier("filters.carplayFit")
                } header: {
                    Text("CarPlay fit")
                } footer: {
                    Text("Whether what a session needs next can be done by voice from a car. Not laptop-only keeps the ones judged CarPlay-ok and the ones not judged yet. A mark the session has moved past counts as untagged.")
                }

                Section {
                    Picker("Board", selection: $board) {
                        ForEach(BoardFilter.allCases) { Text($0.label).tag($0) }
                    }
                    .accessibilityIdentifier("filters.board")
                } header: {
                    Text("Board visibility")
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") {
                        draft = .default
                        board = .onBoard
                    }
                    .accessibilityIdentifier("filters.resetAll")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        let filters = draft
                        let visibility = board
                        dismiss()
                        Task { await model.apply(filters, board: visibility) }
                    }
                    .bold()
                    .accessibilityIdentifier("filters.apply")
                }
            }
            .task {
                board = model.board
                await model.loadFilterOptions()
            }
        }
    }

    private func quick(_ title: String, _ filters: BoardFilters, identifier: String) -> some View {
        Button {
            draft = filters
        } label: {
            HStack {
                Text(title).foregroundStyle(Theme.ink)
                Spacer()
                if draft == filters { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
            }
        }
        .accessibilityIdentifier(identifier)
    }
}
