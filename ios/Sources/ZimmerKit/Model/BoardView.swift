import Foundation

/// The web UI's four board views (`?view=` on the dashboard), as orderings of the rows the
/// list already has. Each is the server's own rule, restated:
///
/// - **Your board** (`Sessions::UserView`): priority above spot, then precedence descending,
///   then oldest first. One list.
/// - **Last touched** (`LAST_TOUCHED_ORDER`): the last time a person acted on the session,
///   else when it was created, newest first. The web UI's default on a phone, and so here.
/// - **Created**: newest first.
/// - **Ranked**: the same order as Your board, as two sections — *Priority*, then the
///   *Spot queue* in the order it will be worked.
public enum BoardView: String, Hashable, Sendable, CaseIterable, Identifiable {
    case yourBoard = "user"
    case lastTouched = "last_touched"
    case created = "created_desc"
    case ranked

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .yourBoard: return "Your board"
        case .lastTouched: return "Last Touched"
        case .created: return "Created"
        case .ranked: return "Ranked"
        }
    }

    /// The rows in this view's order, in sections. Only Ranked has more than one; the
    /// others are a single untitled section.
    public func sections(_ sessions: [SessionSummary]) -> [BoardSection] {
        switch self {
        case .lastTouched:
            return [BoardSection(title: nil, sessions: Self.sorted(sessions, newestFirst: true) { ($0.lastTouchedAt ?? .distantPast) > ($1.lastTouchedAt ?? .distantPast) })]
        case .created:
            return [BoardSection(title: nil, sessions: Self.sorted(sessions, newestFirst: true) { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) })]
        case .yourBoard:
            let (priority, spot) = Self.halves(sessions)
            return [BoardSection(title: nil, sessions: priority + spot)]
        case .ranked:
            let (priority, spot) = Self.halves(sessions)
            return [BoardSection(title: "Priority", sessions: priority), BoardSection(title: "Spot queue", sessions: spot)]
        }
    }

    /// `Session.ranked` over each scheduling class: precedence descending, then oldest first.
    static func halves(_ sessions: [SessionSummary]) -> (priority: [SessionSummary], spot: [SessionSummary]) {
        let ranked = sorted(sessions, newestFirst: false) { a, b in
            let (pa, pb) = (a.precedence ?? 0, b.precedence ?? 0)
            if pa != pb { return pa > pb }
            return (a.createdAt ?? .distantPast) < (b.createdAt ?? .distantPast)
        }
        return (ranked.filter(\.isPriority), ranked.filter { !$0.isPriority })
    }

    /// Sort by `before`, with the id as the last word so equal keys always land the same way:
    /// higher ids first in a newest-first view (timestamps tie at the second, ids do not),
    /// lower first in the ranked order, as `Session.ranked`'s `id: :asc`.
    static func sorted(_ sessions: [SessionSummary], newestFirst: Bool, by before: (SessionSummary, SessionSummary) -> Bool) -> [SessionSummary] {
        sessions.sorted { a, b in
            if before(a, b) { return true }
            if before(b, a) { return false }
            return newestFirst ? a.id > b.id : a.id < b.id
        }
    }
}

public struct BoardSection: Hashable, Sendable, Identifiable {
    public var title: String?
    public var sessions: [SessionSummary]

    public var id: String { title ?? "" }

    public init(title: String?, sessions: [SessionSummary]) {
        self.title = title
        self.sessions = sessions
    }
}
