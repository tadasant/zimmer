import SwiftUI
import ZimmerKit

/// Sessions, most urgent first, filtered by status. "Needs input" is the default filter
/// and the first chip: the phone is for the sessions waiting on a person.
struct SessionListView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingSettings = false

    var body: some View {
        List {
            Section {
                FilterBar()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if let error = model.error {
                Section { ErrorBanner(error: error).listRowInsets(EdgeInsets()) }
            }
            Section {
                if model.sessions.isEmpty && !model.isLoading {
                    EmptyListRow(filter: model.filter)
                }
                ForEach(model.sessions) { session in
                    NavigationLink(value: session.id) {
                        SessionRow(session: session)
                    }
                    .accessibilityIdentifier("session.row.\(session.id)")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Sessions")
        .refreshable { await model.refresh() }
        .overlay {
            if model.isLoading && model.sessions.isEmpty { ProgressView() }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier("settings.open")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { model.showingQuickRouter = true } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("New session")
                    .accessibilityIdentifier("quickrouter.open")
            }
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .sheet(isPresented: $model.showingQuickRouter) { QuickRouterView() }
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

struct SessionRow: View {
    let session: SessionSummary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusDot(status: session.status).padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayTitle)
                    .font(.body.weight(session.status == .needsInput ? .semibold : .regular))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(session.status.label)
                        .foregroundStyle(StatusDot.color(for: session.status))
                    Text("·")
                    // Verbatim: a session id is an identifier, not a quantity to group.
                    Text(verbatim: "#\(session.id)")
                    if let date = session.updatedAt ?? session.createdAt {
                        Text("·")
                        Text(date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct StatusDot: View {
    let status: SessionStatus

    var body: some View {
        Circle().fill(Self.color(for: status)).frame(width: 10, height: 10)
    }

    static func color(for status: SessionStatus) -> Color {
        switch status {
        case .needsInput: return .orange
        case .running: return .blue
        case .waiting: return .gray
        case .failed: return .red
        case .archived: return .secondary
        case .unknown: return .gray
        }
    }
}

private struct EmptyListRow: View {
    let filter: SessionFilter

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: filter == .needsInput ? "checkmark.circle" : "tray")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(filter == .needsInput ? "Nothing needs you right now." : "No \(filter.label.lowercased()) sessions.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .accessibilityIdentifier("sessions.empty")
    }
}
