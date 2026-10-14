import Foundation

/// The quick filters on the session list: one tap each, as the web UI's status chips and
/// its *All* / *All Unarchived* links are. Each sets `BoardFilters`, which is what the list
/// asks the server for; a combination the chips cannot express shows as *Custom*.
///
/// `needsInput` is first and the default: the phone is for the sessions waiting on a person.
public enum SessionFilter: String, Hashable, Sendable, CaseIterable, Identifiable {
    case needsInput
    case active
    case waiting
    case running
    case failed
    case archived

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .needsInput: return "Needs input"
        case .active: return "Active"
        case .waiting: return "Waiting"
        case .running: return "Running"
        case .failed: return "Failed"
        case .archived: return "Archived"
        }
    }

    /// How many pages of 100 a list reads: the web UI's board caps itself at 500 rows.
    public static let maxPages = 5

    /// The filters this chip stands for: its statuses, nothing else narrowed.
    public var filters: BoardFilters {
        switch self {
        case .needsInput: return BoardFilters(statuses: [.needsInput])
        case .active: return BoardFilters()
        case .waiting: return BoardFilters(statuses: [.waiting])
        case .running: return BoardFilters(statuses: [.running])
        case .failed: return BoardFilters(statuses: [.failed])
        case .archived: return BoardFilters(statuses: [.archived])
        }
    }

    /// Whether a session with this status belongs under this chip.
    public func admits(_ status: SessionStatus) -> Bool { filters.admits(status: status) }

    /// Query parameters for `GET /api/v1/sessions`.
    public var query: [String: String] { filters.query }
}

/// What the board's list is narrowed to, every part combining with every other as the web
/// UI's filter form does: any set of statuses, a scheduling class, an agent root and a
/// genesis. Board visibility is `BoardFilter`, kept apart because it has its own menu.
///
/// No statuses means every status but archived — the web UI's *All Unarchived*. Archived
/// sessions appear only when *Archived* is among the statuses, as ticking it does on the web.
public struct BoardFilters: Hashable, Sendable, Codable {
    /// Raw status values (`needs_input`, …), so the set survives being written down.
    public var statuses: Set<String>
    /// `priority` or `spot`; nil for both.
    public var schedulingClass: String?
    /// An agent root's catalog name.
    public var agentRoot: String?
    /// A `SessionGenesis` key.
    public var genesis: String?

    public init(statuses: Set<SessionStatus> = [], schedulingClass: String? = nil, agentRoot: String? = nil, genesis: String? = nil) {
        self.statuses = Set(statuses.map(\.rawValue))
        self.schedulingClass = schedulingClass
        self.agentRoot = agentRoot
        self.genesis = genesis
    }

    /// The phone's default: the sessions waiting on a person.
    public static let `default` = SessionFilter.needsInput.filters
    /// The web UI's quick filters.
    public static let all = BoardFilters(statuses: Set(SessionStatus.allCases))
    public static let allUnarchived = BoardFilters()
    public static let allPriorityUnarchived = BoardFilters(schedulingClass: "priority")
    /// What the Ranked view opens on, as on the web: everything that can still run.
    public static let ranked = BoardFilters(statuses: [.waiting, .running, .needsInput, .failed])

    /// The statuses in the web UI's order, for a summary and for the query.
    public var orderedStatuses: [SessionStatus] {
        SessionStatus.allCases.filter { statuses.contains($0.rawValue) }
    }

    public func includes(_ status: SessionStatus) -> Bool { statuses.contains(status.rawValue) }

    public mutating func toggle(_ status: SessionStatus) {
        if statuses.contains(status.rawValue) { statuses.remove(status.rawValue) } else { statuses.insert(status.rawValue) }
    }

    /// How many things beyond statuses narrow the list: what the Filters button counts.
    public var refinementCount: Int {
        [schedulingClass, agentRoot, genesis].compactMap { $0 }.count
    }

    /// The quick-filter chip these filters are exactly, or nil for a combination of its own.
    public var preset: SessionFilter? {
        SessionFilter.allCases.first { $0.filters == self }
    }

    /// A line saying what is shown: "Needs input, Failed · Priority · zimmer". `genesisLabel`
    /// turns a genesis key into the dashboard's words when the catalog is to hand.
    public func summary(genesisLabel: (String) -> String? = { _ in nil }) -> String {
        var parts: [String] = []
        let shown = orderedStatuses
        if shown.isEmpty {
            parts.append("All unarchived")
        } else if shown.count == SessionStatus.allCases.count {
            parts.append("All statuses")
        } else {
            parts.append(shown.map(\.label).joined(separator: ", "))
        }
        if let schedulingClass { parts.append(schedulingClass.capitalized) }
        if let agentRoot { parts.append(agentRoot) }
        if let genesis { parts.append(genesisLabel(genesis) ?? genesis) }
        return parts.joined(separator: " · ")
    }

    public var summary: String { summary() }

    /// Whether a session's status is among these filters' — what the list keeps of a row the
    /// app has just changed.
    public func admits(status: SessionStatus) -> Bool {
        statuses.isEmpty ? status != .archived : statuses.contains(status.rawValue)
    }

    /// Whether a session belongs under these filters, as far as the app can tell from the row.
    public func admits(_ session: SessionSummary) -> Bool {
        guard admits(status: session.status) else { return false }
        if let schedulingClass, session.priorityClass != schedulingClass { return false }
        if let agentRoot, session.agentRoot != agentRoot { return false }
        if let genesis, session.genesis != genesis { return false }
        return true
    }

    /// Query parameters for `GET /api/v1/sessions` and `/search`: statuses comma-separated,
    /// which the server reads as several, and naming archived brings archived sessions in.
    public var query: [String: String] {
        var query = ["per_page": "100"]
        let shown = orderedStatuses
        if !shown.isEmpty { query["status"] = shown.map(\.rawValue).joined(separator: ",") }
        if includes(.archived) { query["show_archived"] = "true" }
        if let schedulingClass { query["priority_class"] = schedulingClass }
        if let agentRoot { query["agent_root"] = agentRoot }
        if let genesis { query["genesis"] = genesis }
        return query
    }
}

public enum SessionOrdering {
    /// Most urgent status first, then most recently touched. Stable for equal keys, so a
    /// refresh does not shuffle rows that did not change.
    public static func sorted(_ sessions: [SessionSummary]) -> [SessionSummary] {
        sessions.enumerated().sorted { lhs, rhs in
            let (a, b) = (lhs.element, rhs.element)
            if a.status.urgency != b.status.urgency { return a.status.urgency < b.status.urgency }
            let aDate = a.updatedAt ?? a.createdAt ?? .distantPast
            let bDate = b.updatedAt ?? b.createdAt ?? .distantPast
            if aDate != bDate { return aDate > bDate }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}
