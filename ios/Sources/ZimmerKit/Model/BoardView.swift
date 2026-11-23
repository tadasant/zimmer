import Foundation

/// The web UI's board views (`?view=` on the dashboard), as orderings of the rows the list
/// already has. Each is the server's own rule, restated:
///
/// - **Your board** (`Sessions::BoardV2`, `?view=board_v2`): the person's own categories.
///   Uncategorized first, then each category in the person's order, each most recently
///   touched first, as Last Touched orders them. A collapsed category is its header alone; a
///   snoozed or backlogged one is off the board with its rows and listed at the foot. The
///   app's default.
/// - **Last touched** (`LAST_TOUCHED_ORDER`): the last time a person acted on the session,
///   else when it was created, newest first.
/// - **Created**: newest first.
/// - **Ranked** (`Sessions::RankedOrder`): priority above spot, then precedence descending, then
///   oldest first, as two sections — *Priority*, then the *Spot queue* in the order it will
///   be worked.
public enum BoardView: String, Hashable, Sendable, CaseIterable, Identifiable {
    case boardV2 = "board_v2"
    case lastTouched = "last_touched"
    case created = "created_desc"
    case ranked

    /// The view the board opens on when the person has not chosen one: Your board, Last
    /// Touched's compact rows under the person's own categories. A choice once made is kept.
    public static let defaultView: BoardView = .boardV2

    /// The view a remembered choice names. `"user"` is the board the dashboard drew before
    /// Your board was the person's categories; the server answers `?view=user` with the same
    /// board, so a person who chose it lands on Your board. Nothing remembered, or a value no
    /// view has, is the default.
    public static func remembered(_ rawValue: String?) -> BoardView {
        guard let rawValue else { return defaultView }
        if rawValue == "user" { return .boardV2 }
        return BoardView(rawValue: rawValue) ?? defaultView
    }

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .boardV2: return "Your board"
        case .lastTouched: return "Last Touched"
        case .created: return "Created"
        case .ranked: return "Ranked"
        }
    }

    /// The title of Your board's first section, where every session nobody has put in a
    /// category lands.
    public static let uncategorized = "Uncategorized"

    /// The rows in this view's order, in sections. Ranked has two and Your board one per
    /// category; the others are a single untitled section.
    ///
    /// `order` is where a drag just left the rows, by id, before the server has answered with
    /// the precedence it worked out: the reorderable view shows that order until the list is
    /// read again, so a dropped row does not snap back while the server is asked. Rows it does
    /// not name keep their place behind the ones it does.
    ///
    /// `categories` is Your board's categories in board order, as the server last listed
    /// them; the other views do not read it.
    public func sections(_ sessions: [SessionSummary], order: [Int]? = nil, categories: [BoardCategory] = []) -> [BoardSection] {
        switch self {
        case .boardV2:
            return Self.categorized(sessions, categories: categories)
        case .lastTouched:
            return [BoardSection(title: nil, sessions: Self.lastTouchedFirst(sessions))]
        case .created:
            return [BoardSection(title: nil, sessions: Self.sorted(sessions, newestFirst: true) { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) })]
        case .ranked:
            let (priority, spot) = Self.halves(sessions)
            return [BoardSection(title: "Priority", sessions: Self.arranged(priority, by: order)), BoardSection(title: "Spot queue", sessions: Self.arranged(spot, by: order))]
        }
    }

    /// Most recently touched first: the last time a person acted on the session, else when it
    /// was created.
    static func lastTouchedFirst(_ sessions: [SessionSummary]) -> [SessionSummary] {
        sorted(sessions, newestFirst: true) { ($0.lastTouchedAt ?? .distantPast) > ($1.lastTouchedAt ?? .distantPast) }
    }

    /// Your board: Uncategorized, then every category on the board in the order given, each
    /// most recently touched first. A row whose category is not listed (deleted since) is
    /// Uncategorized, as the server's `ON DELETE SET NULL` makes it; one in a category that is
    /// tucked away is not drawn, as the server does not list it. A collapsed category keeps
    /// its count and draws no rows.
    static func categorized(_ sessions: [SessionSummary], categories: [BoardCategory]) -> [BoardSection] {
        let known = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var grouped: [Int?: [SessionSummary]] = [:]
        for session in lastTouchedFirst(sessions) {
            let key = session.boardCategoryID.flatMap { known[$0] == nil ? nil : $0 }
            if let key, known[key]?.onBoard == false { continue }
            grouped[key, default: []].append(session)
        }
        let loose = BoardSection(title: uncategorized, sessions: grouped[nil] ?? [], key: "uncategorized")
        return [loose] + categories.filter(\.onBoard).map { category in
            let rows = grouped[category.id] ?? []
            return BoardSection(title: category.name, sessions: category.collapsed ? [] : rows, key: "category.\(category.id)",
                                category: category, count: rows.count)
        }
    }

    /// `rows` in the order `order` names them, the rows it does not name after, as they were.
    static func arranged(_ rows: [SessionSummary], by order: [Int]?) -> [SessionSummary] {
        guard let order, !order.isEmpty else { return rows }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let named = rows.filter { rank[$0.id] != nil }.sorted { rank[$0.id]! < rank[$1.id]! }
        return named + rows.filter { rank[$0.id] == nil }
    }

    /// The rows a drop landed between, as the web UI's Ranked view names them: the nearest of the
    /// moved row's own class above and below. Precedence orders a class and cannot lift a row
    /// out of it, so a row dropped among the other class is placed by its own neighbours and
    /// settles back into its block when the list is read again. The server reads only spot
    /// rows as neighbours, as the web UI's drag does.
    public static func dropNeighbours(_ rows: [SessionSummary], at index: Int) -> (above: Int?, below: Int?) {
        guard rows.indices.contains(index) else { return (nil, nil) }
        let priority = rows[index].isPriority
        let above = rows[..<index].last { $0.isPriority == priority }?.id
        let below = rows[(index + 1)...].first { $0.isPriority == priority }?.id
        return (above, below)
    }

    /// Whether a person orders this view by dragging: Ranked's spot queue. Your board's rows
    /// move between categories, not into an order.
    public var isReorderable: Bool { self == .ranked }

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
    /// The rows drawn: none for a collapsed Your board category.
    public var sessions: [SessionSummary]
    /// What tells this section from the others: its title, unless it says otherwise. Your
    /// board's are keyed by category, since a person could name one "Uncategorized".
    public var key: String?
    /// The Your board category this section draws; nil for Uncategorized and other views.
    public var category: BoardCategory?
    /// How many rows the section holds, drawn or not.
    public var count: Int

    public var id: String { key ?? title ?? "" }

    /// The section is a category's header alone.
    public var isCollapsed: Bool { category?.collapsed ?? false }

    public init(title: String?, sessions: [SessionSummary], key: String? = nil, category: BoardCategory? = nil, count: Int? = nil) {
        self.title = title
        self.sessions = sessions
        self.key = key
        self.category = category
        self.count = count ?? sessions.count
    }
}
