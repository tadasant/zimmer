import SwiftUI
import ZimmerKit

/// Goal check, goal, notes, MCP servers, skills/hooks/plugins, hierarchy and human messages:
/// one card, hairlines between the rows. The MCP servers and the other three are always
/// there, each with its Edit — or Add, when the session has none — as the web page's are. Goal and notes clamp to two lines and open on a tap; the hierarchy folds
/// when it is wide, the human messages always, each saying in its closed row what it holds.
struct DetailsCard: View {
    let detail: SessionDetail
    /// The catalog goal the session's goal names, when the catalog has read.
    let goal: GoalOption?
    /// The catalog has read, so a goal it does not name is free text.
    var catalogRead = false
    /// Open the folded rows from the start: the fixture's photograph of them.
    var expanded = false
    /// Bumped by the page's section strip to open the hierarchy's or the human messages' row.
    var opensHierarchy = 0
    var opensHumanMessages = 0
    /// The strip's bottom edge and what has scrolled up to it: the two rows are its sections.
    var sectionEdge: CGFloat = 0
    var reachedSections: Binding<Set<SessionPageSection>> = .constant([])
    let edit: (SessionDetailView.EditedText) -> Void
    /// What the session's agent root supplies of a kind, shown when the session chooses none.
    var rootDefaults: (CatalogKind) -> [String] = { _ in [] }
    let editCatalog: (CatalogKind) -> Void
    let detach: (Int, Int) -> Void

    private enum Row: Identifiable {
        case goalCheck(GoalCheck)
        case goal(String)
        case notes(String)
        case mcpServers([McpConnection])
        case artifacts
        case hierarchy(SessionHierarchy)
        case humanMessages

        var id: String {
            switch self {
            case .goalCheck: return "goalCheck"
            case .goal: return "goal"
            case .notes: return "notes"
            case .mcpServers: return "mcpServers"
            case .artifacts: return "artifacts"
            case .hierarchy: return "hierarchy"
            case .humanMessages: return "humanMessages"
            }
        }
    }

    private var rows: [Row] {
        var rows: [Row] = []
        if let check = detail.goalCheck, !check.criteria.isEmpty { rows.append(.goalCheck(check)) }
        if let goal = detail.session.goal, !goal.isEmpty { rows.append(.goal(goal)) }
        if detail.session.hasNotes, let notes = detail.session.notes { rows.append(.notes(notes)) }
        rows.append(.mcpServers(detail.session.mcpConnections))
        rows.append(.artifacts)
        if let hierarchy = detail.hierarchy, hierarchy.isWorthShowing { rows.append(.hierarchy(hierarchy)) }
        // A capture gap is worth the row on its own: it says an empty list is not "nobody spoke".
        if !detail.humanMessages.isEmpty || !detail.captureGaps.isEmpty { rows.append(.humanMessages) }
        return rows
    }

    var body: some View {
        let rows = rows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Theme.rule.frame(height: 1) }
                    view(for: row)
                        .padding(.vertical, 9)
                        .padding(.horizontal, 12)
                        // The whole row under the strip when a chip jumps to it, padding and all.
                        .pageSection(section(for: row), edge: sectionEdge, reached: reachedSections)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .themeCard(radius: Theme.smallRadius)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("detail.panels")
        }
    }

    @ViewBuilder
    private func view(for row: Row) -> some View {
        switch row {
        case let .goalCheck(check):
            GoalCheckRow(check: check)
        case let .goal(text):
            // The goal check's name stands in only until the catalog reads: after that, a goal
            // the catalog does not name is free text, whatever an older check said.
            GoalRow(text: text, goal: goal, checkedName: catalogRead ? nil : detail.goalCheck?.goalName) { edit(.goal) }
        case let .notes(notes):
            ClampedTextRow(title: "Notes", text: notes, identifier: "detail.notes") { edit(.notes) }
        case let .mcpServers(connections):
            McpServersRow(connections: connections, rootDefaults: rootDefaults(.mcpServers)) { editCatalog(.mcpServers) }
        case .artifacts:
            ArtifactsRow(session: detail.session, rootDefaults: rootDefaults, edit: editCatalog)
        case let .hierarchy(hierarchy):
            HierarchyRow(hierarchy: hierarchy, startsOpen: expanded, opens: opensHierarchy, detach: detach)
        case .humanMessages:
            HumanMessagesRow(detail: detail, startsOpen: expanded, opens: opensHumanMessages)
        }
    }

    /// The page section a row is the top of, for the section strip.
    private func section(for row: Row) -> SessionPageSection? {
        switch row {
        case .hierarchy: return .hierarchy
        case .humanMessages: return .humanMessages
        case .goalCheck, .goal, .notes, .mcpServers, .artifacts: return nil
        }
    }
}

/// The web UI's Goal check panel: the verdict and its tally, whose PRs were judged when they
/// were the spawned sessions' rather than this one's, then one line per criterion.
private struct GoalCheckRow: View {
    let check: GoalCheck

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("Goal check").themeLabel()
                Text(check.verdict.capitalized)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .foregroundStyle(Self.verdictColors(check.verdict).text)
                    .background(Self.verdictColors(check.verdict).fill, in: Capsule())
                Spacer(minLength: 0)
            }
            Text(verbatim: check.tally)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.inkMute)
                .accessibilityIdentifier("detail.goalcheck.tally")
            if !check.delegatedSessionIDs.isEmpty {
                // As on the web: each session a link, the sentence around them.
                FlowLayout(spacing: 4, rowSpacing: 2) {
                    Text("Judged on PRs recorded by")
                    ForEach(check.delegatedSessionIDs, id: \.self) { id in
                        NavigationLink(value: id) {
                            Text(verbatim: "session #\(id)").underline().foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Session #\(id)")
                        .accessibilityIdentifier("goalcheck.delegate.\(id)")
                    }
                    Text("which this session spawned.")
                }
                .font(.caption)
                .foregroundStyle(Theme.inkSoft)
            }
            ForEach(check.criteria) { criterion in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Self.mark(criterion.status).0)
                        .font(.caption.weight(.bold).monospaced())
                        .foregroundStyle(Self.mark(criterion.status).1)
                        .frame(width: 12)
                    Text(criterion.label).font(.subheadline).foregroundStyle(Theme.ink)
                    if let detail = criterion.detail, !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(Theme.inkMute).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            if let note = check.note, !note.isEmpty {
                Text(note).font(.caption2).foregroundStyle(Theme.inkMute).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.goalcheck")
    }

    /// `_goal_check_panel.html.erb`'s marks and colours.
    static func mark(_ status: String) -> (String, Color) {
        switch status {
        case "met": return ("✓", Theme.success)
        case "unmet": return ("✗", Theme.danger)
        case "pending": return ("…", Theme.ci("pending"))
        default: return ("?", Theme.inkMute)
        }
    }

    static func verdictColors(_ verdict: String) -> Theme.StatusColors {
        switch verdict {
        case "met": return Theme.status(.running)
        case "unmet": return Theme.status(.failed)
        default: return Theme.status(.waiting)
        }
    }
}

/// The goal, as the web page shows it: a catalog goal by its name, with its words under it,
/// two lines until tapped; your own words as they are. The web page says "Custom" and keeps
/// the words for a hover; a phone has no hover, so the words are the display.
private struct GoalRow: View {
    let text: String
    let goal: GoalOption?
    /// The goal check's name for the goal, for before the catalog has read.
    let checkedName: String?
    let edit: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text("Goal").themeLabel()
                Spacer()
                Button("Edit", action: edit)
                    .font(.caption.weight(.medium))
                    .accessibilityIdentifier("detail.goal.edit")
            }
            if let name {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .accessibilityIdentifier("detail.goal.name")
            }
            if let words {
                Text(words)
                    .font(name == nil ? .subheadline : .caption)
                    .foregroundStyle(name == nil ? Theme.ink : Theme.inkSoft)
                    .lineLimit(expanded ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } }
                    // A tap expands, so the words are copied from a long press rather than
                    // selected: selection and a tap gesture on one text, on a page that moves as
                    // it reads again, took the app down in the UI tests.
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = words }
                    }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.goal")
    }

    private var name: String? { goal?.title ?? checkedName }

    /// The words under the name: the catalog's description, or the goal as stored unless it
    /// is only the id the name already stands for.
    private var words: String? {
        if let description = goal?.description, !description.isEmpty { return description }
        if name != nil, text == goal?.id || !text.contains(" ") { return nil }
        return text
    }
}

/// A titled block of text with an Edit button, clamped to two lines until tapped: the notes.
private struct ClampedTextRow: View {
    let title: String
    let text: String
    let identifier: String
    let edit: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).themeLabel()
                Spacer()
                Button("Edit", action: edit).font(.caption.weight(.medium))
            }
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
                .lineLimit(expanded ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } }
                // Copied from a long press, as the goal's words are: selection with the tap
                // that expands, on a page that moves as it reads again, takes the app down.
                .contextMenu {
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

/// The web UI's MCP chips: each server the session has wired and whether its agent reached
/// it — green, red, grey while pending — the injected ones dashed. A failed server's error is
/// a tap away, as the web chip's popover is.
private struct McpServersRow: View {
    let connections: [McpConnection]
    let rootDefaults: [String]
    let edit: () -> Void
    @State private var showingError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("MCP servers").themeLabel()
                if !connections.isEmpty {
                    Text(verbatim: tally).font(.caption2.monospacedDigit()).foregroundStyle(Theme.inkMute)
                }
                Spacer()
                Button(connections.isEmpty ? "Add" : "Edit", action: edit)
                    .font(.caption.weight(.medium))
                    .accessibilityLabel(connections.isEmpty ? "Add MCP servers" : "Edit MCP servers")
                    .accessibilityIdentifier("detail.mcp.edit")
            }
            if connections.isEmpty {
                EmptySelection(rootDefaults: rootDefaults).accessibilityIdentifier("detail.mcp.none")
            }
            FlowLayout(spacing: 5, rowSpacing: 5) {
                ForEach(connections) { connection in
                    if connection.error?.isEmpty == false {
                        Button {
                            withAnimation(.snappy(duration: 0.2)) {
                                showingError = showingError == connection.name ? nil : connection.name
                            }
                        } label: {
                            chip(connection)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows the error.")
                    } else {
                        chip(connection)
                    }
                }
            }
            if let name = showingError, let error = connections.first(where: { $0.name == name })?.error {
                Text(verbatim: "\(name): \(error)")
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("mcp.error.\(name)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.mcp")
    }

    /// "2 of 3 connected".
    private var tally: String {
        "\(connections.filter { $0.state == .connected }.count) of \(connections.count) connected"
    }

    private func chip(_ connection: McpConnection) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let tint = Self.tint(connection.state)
        return HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(connection.name)
                .italic(connection.injected || connection.fromPlugin)
                .foregroundStyle(connection.fromPlugin ? Theme.inkSoft : Theme.ink)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(connection.state == .pending ? Theme.well : tint.opacity(0.12), in: shape)
        .overlay {
            shape.strokeBorder(tint.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: connection.injected ? [3, 2] : []))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(connection.name): \(connection.state.label)\(connection.injected ? ", added by Zimmer" : "")\(connection.fromPlugin ? ", from a plugin" : "")")
        .accessibilityIdentifier("mcp.server.\(connection.name)")
    }

    static func tint(_ state: McpConnection.State) -> Color {
        switch state {
        case .connected: return Theme.success
        case .failed: return Theme.danger
        case .pending: return Theme.inkMute
        }
    }
}

/// What an empty list says: the agent root's defaults where it has some, as the web page's
/// "agent root default", else None.
private struct EmptySelection: View {
    let rootDefaults: [String]

    var body: some View {
        Group {
            if rootDefaults.isEmpty {
                Text("None").italic()
            } else {
                Text(verbatim: "\(rootDefaults.joined(separator: ", ")) (agent root default)")
            }
        }
        .font(.caption)
        .foregroundStyle(Theme.inkMute)
    }
}

/// The session's skills, hooks and plugins, a line each with its Edit — or Add, when the
/// session has none — as the web page's metadata block lists them beside the MCP servers.
private struct ArtifactsRow: View {
    let session: SessionSummary
    let rootDefaults: (CatalogKind) -> [String]
    let edit: (CatalogKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach([CatalogKind.skills, .hooks, .plugins]) { kind in
                line(kind)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.artifacts")
    }

    private func line(_ kind: CatalogKind) -> some View {
        let chosen = kind.selection(in: session)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(kind.label).themeLabel()
                if !chosen.isEmpty {
                    Text(verbatim: "\(chosen.count)").font(.caption2.monospacedDigit()).foregroundStyle(Theme.inkMute)
                }
                Spacer()
                Button(chosen.isEmpty ? "Add" : "Edit") { edit(kind) }
                    .font(.caption.weight(.medium))
                    .accessibilityLabel("\(chosen.isEmpty ? "Add" : "Edit") \(kind.label.lowercased())")
                    .accessibilityIdentifier("detail.\(kind.rawValue).edit")
            }
            if chosen.isEmpty {
                EmptySelection(rootDefaults: rootDefaults(kind))
                if kind != .plugins, !(session.catalogPlugins ?? []).isEmpty {
                    // The web lists what the plugins bring; the API does not say, so say they may.
                    Text("Its plugins may bring some.").font(.caption).foregroundStyle(Theme.inkMute)
                }
            } else {
                FlowLayout(spacing: 5, rowSpacing: 5) {
                    ForEach(chosen, id: \.self) { id in
                        Text(verbatim: id)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Theme.well, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.\(kind.rawValue)")
    }
}

/// The web UI's hierarchy panel: who spawned this session and what it spawned, indented by
/// depth, each with its agent root and its genesis and class, the origin marked and a row
/// drawn under a session that did not spawn it tagged. Every other session in it opens on a
/// tap. A tree of more than four folds, and its closed row says how big it is.
private struct HierarchyRow: View {
    let hierarchy: SessionHierarchy
    /// Remove an "also senior" edge: (junior, uncle).
    let detach: (Int, Int) -> Void
    /// Bumped to open the row: the section strip jumping to it.
    var opens = 0
    @State private var open: Bool
    @State private var detaching: (junior: Int, uncle: Int)?

    init(hierarchy: SessionHierarchy, startsOpen: Bool = false, opens: Int = 0, detach: @escaping (Int, Int) -> Void) {
        self.hierarchy = hierarchy
        self.opens = opens
        self.detach = detach
        _open = State(initialValue: startsOpen || hierarchy.nodes.count <= 4)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(hierarchy.nodes) { node in
                    VStack(alignment: .leading, spacing: 2) {
                        if node.current {
                            row(node)
                        } else {
                            NavigationLink(value: node.id) { row(node) }
                                .buttonStyle(.plain)
                        }
                        // Beside the link, not in it, so a detach is never taken as opening the session.
                        if !node.uncles.isEmpty { seniors(node) }
                    }
                }
                if hierarchy.truncated {
                    Text(hierarchy.truncationReason ?? "Only part of the hierarchy is shown.")
                        .font(.caption)
                        .foregroundStyle(Theme.banner(.warning).text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(Theme.inkMute)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Text("Hierarchy").themeLabel()
                Text(verbatim: hierarchy.summary).font(.caption2.monospacedDigit()).foregroundStyle(Theme.inkMute)
            }
        }
        .tint(Theme.inkMute)
        .onChange(of: opens) { _, _ in withAnimation(.snappy(duration: 0.25)) { open = true } }
        .confirmationDialog(
            detaching.map { "Remove #\($0.uncle) as an additional senior of #\($0.junior)?" } ?? "",
            isPresented: Binding(get: { detaching != nil }, set: { if !$0 { detaching = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let edge = detaching { detach(edge.junior, edge.uncle) }
            }
        } message: {
            Text("Both sessions stop pulling in the other's human messages through this edge. Spawn parents are untouched, and both timelines record the removal.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.hierarchy")
    }

    /// The web panel's reading notes, cut to what a phone needs.
    private var footnote: String {
        var text = "Indented means spawned, not most recently talked to. The second line is the agent root, then the genesis and the class it runs under."
        if hierarchy.hasRedrawnEdges {
            text += " A row marked drawn under was not spawned by the session it sits under: Zimmer reached it another way."
        }
        return text
    }

    private func row(_ node: SessionHierarchy.Node) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                StatusDot(status: node.status, size: 7)
                Text(node.displayTitle)
                    .lineLimit(1)
                    .fontWeight(node.current ? .semibold : .regular)
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 4)
                Text(verbatim: "#\(node.id)").font(Theme.mono).foregroundStyle(Theme.inkMute)
                if !node.current {
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(Theme.inkMute)
                }
            }
            .font(.subheadline)
            HStack(spacing: 4) {
                if node.current {
                    Text("this session").foregroundStyle(Theme.accent)
                }
                if let marker = hierarchy.rootMarker(for: node) {
                    Text(marker).foregroundStyle(Theme.accent)
                }
                Text(verbatim: details(node)).foregroundStyle(Theme.inkMute)
                if !node.spawnEdge {
                    Text(verbatim: node.renderParentID.map { "drawn under #\($0)" } ?? "drawn here, no parent row")
                        .foregroundStyle(Theme.banner(.warning).text)
                }
            }
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            // In line with the title, past the status dot.
            .padding(.leading, 13)
        }
        .padding(.leading, CGFloat(min(node.depth, 6)) * 12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("hierarchy.node.\(node.id)")
    }

    /// "zimmer · slack · spot": the agent root, then the web panel's genesis pill.
    private func details(_ node: SessionHierarchy.Node) -> String {
        [node.agentRoot, node.genesisLine].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The web UI's amber "also senior" chips: the sessions that queued or interrupted this
    /// one, each with its own detach.
    private func seniors(_ node: SessionHierarchy.Node) -> some View {
        HStack(spacing: 4) {
            Text("also senior:")
            ForEach(node.uncles, id: \.self) { uncle in
                // As on the web: the number opens that session, only the × detaches.
                HStack(spacing: 2) {
                    NavigationLink(value: uncle) { Text(verbatim: "#\(uncle)").underline() }
                        .buttonStyle(.plain)
                    Button {
                        detaching = (node.id, uncle)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove #\(uncle) as an additional senior of #\(node.id)")
                    .accessibilityIdentifier("hierarchy.uncle.\(node.id).\(uncle)")
                }
            }
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(Theme.status(.failed).text)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Theme.status(.failed).fill, in: Capsule())
        .padding(.leading, CGFloat(min(node.depth, 6)) * 12 + 14)
    }
}

/// The web UI's Human messages panel, folded: both counts in the closed row, then any channel
/// Zimmer cannot capture (which makes the counts a floor), then each message with who said
/// it, through which channel, and whether to this session or to another in its family — the
/// session it was said in a tap away.
private struct HumanMessagesRow: View {
    let detail: SessionDetail
    /// Bumped to open the row: the section strip jumping to it.
    var opens = 0
    @State private var open: Bool

    init(detail: SessionDetail, startsOpen: Bool = false, opens: Int = 0) {
        self.detail = detail
        self.opens = opens
        _open = State(initialValue: startsOpen)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(detail.captureGaps) { gap in
                    captureGap(gap)
                }
                if detail.humanMessages.isEmpty {
                    // The web panel's empty state, in its words.
                    Text("Zimmer captured no human message anywhere in this hierarchy — and capture is not configured for \(detail.uncapturedChannels), \(detail.captureGaps.count == 1 ? "one of the channels" : "channels") this hierarchy's work arrived over. Read this as the check could not be established, not as \"no human spoke\".")
                        .font(.caption)
                        .foregroundStyle(Theme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(detail.humanMessages) { message in
                    entry(message)
                }
                if detail.humanMessages.contains(where: { !$0.isHere }) {
                    Text("Elsewhere is a person speaking to another session in this hierarchy: context about what was first asked for, not an instruction to this session.")
                        .font(.caption2)
                        .foregroundStyle(Theme.inkMute)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 6)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Human messages").themeLabel()
                Text(verbatim: detail.humanMessagesSummary)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(detail.captureGaps.isEmpty ? Theme.inkMute : Theme.banner(.warning).text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("detail.humanmessages.summary")
            }
        }
        .tint(Theme.inkMute)
        .onChange(of: opens) { _, _ in withAnimation(.snappy(duration: 0.25)) { open = true } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.humanmessages")
    }

    /// The web panel's amber notice: which channel, why, and what fixes it.
    private func captureGap(_ gap: HumanMessageCaptureGap) -> some View {
        let colors = Theme.banner(.warning)
        return VStack(alignment: .leading, spacing: 4) {
            Text(gap.headline).font(.caption.weight(.semibold))
            if let reason = gap.reason {
                Text(reason).font(.caption)
            }
            Text("So the counts here are a floor for \(gap.channelLabel): a person may have spoken there and Zimmer could not see it.")
                .font(.caption)
            if let remedy = gap.remedy {
                Text(remedy).font(.caption)
            }
        }
        .foregroundStyle(colors.text)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(colors.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("humanmessages.gap.\(gap.channel)")
    }

    private func entry(_ message: HumanMessage) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            FlowLayout(spacing: 4, rowSpacing: 2) {
                Text(message.isHere ? "this session" : "elsewhere")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .foregroundStyle(message.isHere ? Theme.accent : Theme.inkSoft)
                    .background(message.isHere ? Theme.accent.opacity(0.14) : Theme.well, in: Capsule())
                if let author = message.author {
                    Text(author).font(.caption2.weight(.semibold)).foregroundStyle(Theme.ink)
                }
                if let channel = message.channelLabel {
                    Text(verbatim: "· \(channel)")
                }
                if !message.isHere, let id = message.authoredInSessionID {
                    Text("· said in")
                    NavigationLink(value: id) {
                        Text(verbatim: "#\(id)").underline().foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Session #\(id)")
                    .accessibilityIdentifier("humanmessage.saidin.\(id)")
                    if let title = message.authoredInTitle {
                        Text(title).lineLimit(1)
                    }
                }
                if let date = message.occurredAt {
                    Text(verbatim: "· \(Format.age(date))").monospacedDigit()
                }
            }
            .font(.caption2)
            .foregroundStyle(Theme.inkMute)
            Text(message.content)
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(message.isHere ? "humanmessage.here" : "humanmessage.elsewhere")
    }
}

/// The web page's goal picker, as a sheet: the catalog's goals by name with their words under
/// them, a tap to choose one; or your own words; or none. A catalog goal is stored as its
/// words, as the web picker stores it. `save` reports whether the server took it; the sheet
/// stays open when it did not.
struct GoalPickerSheet: View {
    let goals: [GoalOption]
    let current: String?
    let save: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var custom = ""
    @State private var saving = false

    // Spelled out: the private state makes the memberwise one private to this file.
    init(goals: [GoalOption], current: String?, save: @escaping (String) async -> Bool) {
        self.goals = goals
        self.current = current
        self.save = save
    }

    var body: some View {
        NavigationStack {
            List {
                if !goals.isEmpty {
                    Section("From the catalog") {
                        ForEach(goals) { goal in
                            Button {
                                choose(goal.storedValue)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(goal.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                                        if let words = goal.description, !words.isEmpty {
                                            Text(words).font(.caption).foregroundStyle(Theme.inkSoft).lineLimit(3)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    if selected?.id == goal.id {
                                        Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Theme.accent)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(saving)
                            .accessibilityIdentifier("goal.option.\(goal.id)")
                        }
                    }
                }
                Section {
                    TextField("When is this session done?", text: $custom, axis: .vertical)
                        .lineLimit(2...6)
                        .font(.subheadline)
                        .accessibilityIdentifier("goal.custom.field")
                    Button(saving ? "Saving…" : "Use these words") {
                        choose(custom.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    .disabled(saving || custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("goal.custom.save")
                } header: {
                    Text("In your own words")
                }
                if !(current ?? "").isEmpty {
                    Section {
                        Button("Clear the goal", role: .destructive) { choose("") }
                            .disabled(saving)
                            .accessibilityIdentifier("goal.clear")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ground)
            .navigationTitle("Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear {
                // Your own words start where they were; a catalog goal starts the field empty.
                if selected == nil { custom = current ?? "" }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// The catalog goal the session has now, matched as the server matches it.
    private var selected: GoalOption? {
        GoalOption.matching(current, in: goals)
    }

    private func choose(_ value: String) {
        guard !saving else { return }
        Task {
            saving = true
            let saved = await save(value)
            saving = false
            if saved { dismiss() }
        }
    }
}
