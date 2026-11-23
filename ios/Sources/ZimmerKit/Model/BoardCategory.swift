import Foundation

/// One of the person's own Your board v2 categories (`BoardCategory` on the server), as
/// `GET /api/v1/sessions?view=board_v2` lists them in `board_categories`, in board order.
///
/// Entirely manual: a person creates a category and puts sessions in it, and nothing sorts a
/// session into one on its own. Every field beyond `id` and `name` is read without throwing,
/// so a server that adds or drops one degrades a category rather than the whole board.
public struct BoardCategory: Hashable, Sendable, Codable, Identifiable {
    public let id: Int
    public var name: String
    /// Where the category sits on the board, top first.
    public var position: Int?
    /// The section shows its header only. Stored on the category, so it follows the person
    /// between the web UI and the phone.
    public var collapsed: Bool
    /// The stored choice: `visible`, `snoozed` or `backlogged`, for the whole category.
    public var visibility: SessionVisibility?
    public var snoozedUntil: Date?
    /// Whether the board draws the category's rows. A snoozed or backlogged category is
    /// tucked away as a unit: its rows are not listed, and it is drawn at the foot with a count.
    public var onBoard: Bool
    /// The listed rows the category holds, or, when it is tucked away, how many sessions are.
    public var sessionCount: Int?

    public init(id: Int, name: String, position: Int? = nil, collapsed: Bool = false,
                visibility: SessionVisibility? = .visible, snoozedUntil: Date? = nil,
                onBoard: Bool = true, sessionCount: Int? = nil) {
        self.id = id
        self.name = name
        self.position = position
        self.collapsed = collapsed
        self.visibility = visibility
        self.snoozedUntil = snoozedUntil
        self.onBoard = onBoard
        self.sessionCount = sessionCount
    }

    enum CodingKeys: String, CodingKey {
        case id, name, position, collapsed, visibility
        case snoozedUntil = "snoozed_until"
        case onBoard = "on_board"
        case sessionCount = "session_count"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? "Category \(id)"
        position = try? container.decodeIfPresent(Int.self, forKey: .position)
        collapsed = (try? container.decodeIfPresent(Bool.self, forKey: .collapsed)) ?? false
        visibility = try? container.decodeIfPresent(SessionVisibility.self, forKey: .visibility)
        snoozedUntil = try? container.decodeIfPresent(Date.self, forKey: .snoozedUntil)
        onBoard = (try? container.decodeIfPresent(Bool.self, forKey: .onBoard)) ?? true
        sessionCount = try? container.decodeIfPresent(Int.self, forKey: .sessionCount)
    }

    /// Why a tucked-away category is off the board, as the web board's tray says it.
    public var tuckedLabel: String {
        if visibility == .backlogged { return "Backlogged" }
        if let snoozedUntil { return "Snoozed until \(snoozedUntil.formatted(date: .abbreviated, time: .shortened))" }
        return "Snoozed"
    }
}

/// `PATCH /api/v1/board_categories/:id` and its `visibility`: the category as it now stands.
struct BoardCategoryEnvelope: Decodable {
    let board_category: BoardCategory
}
