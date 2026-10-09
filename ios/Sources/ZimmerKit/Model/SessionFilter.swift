import Foundation

/// The status filters on the session list, and what each asks the server for.
///
/// `needsInput` is first and the default: the phone is for the sessions waiting on a person.
public enum SessionFilter: String, Hashable, Sendable, CaseIterable, Identifiable {
    case needsInput
    case active
    case running
    case failed
    case archived

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .needsInput: return "Needs input"
        case .active: return "Active"
        case .running: return "Running"
        case .failed: return "Failed"
        case .archived: return "Archived"
        }
    }

    /// Query parameters for `GET /api/v1/sessions`. `active` sends no status, which the
    /// server answers with every session that is not archived.
    public var query: [String: String] {
        var query = ["per_page": "100"]
        switch self {
        case .needsInput: query["status"] = SessionStatus.needsInput.rawValue
        case .active: break
        case .running: query["status"] = SessionStatus.running.rawValue
        case .failed: query["status"] = SessionStatus.failed.rawValue
        case .archived:
            query["status"] = SessionStatus.archived.rawValue
            query["show_archived"] = "true"
        }
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
