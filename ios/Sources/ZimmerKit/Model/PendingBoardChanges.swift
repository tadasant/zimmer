import Foundation

/// What this device has done to the board and not yet heard back about.
///
/// A row action is shown the moment it is tapped — the row goes, or changes — and the server
/// is asked afterwards. Until it answers, every read of the list is the server from before the
/// action, and would put the row back as it was. So each change in flight is laid over every
/// read that lands while it is out (`overlay`), and ends when the answer comes (`end`), whether
/// the answer kept the change or the row has to be put back.
///
/// Two actions on one row may be out at once (a snooze, then a trash). The newest stands in for
/// the row; an older one's answer no longer ends anything.
public struct PendingBoardChanges: Sendable {
    /// What the board shows for a row while its action is out.
    public enum Change: Hashable, Sendable {
        /// The row left the list: trashed, hidden, snoozed off the board.
        case removed
        /// The row as it will read once the action lands.
        case replaced(SessionSummary)
    }

    /// One change in flight, for `end`.
    public struct Ticket: Hashable, Sendable {
        public let id: Int
        fileprivate let serial: Int
    }

    private struct Entry: Sendable {
        var serial: Int
        var change: Change
    }

    private var entries: [Int: Entry] = [:]
    private var serial = 0

    public init() {}

    /// A change to the row with `id` is going out. Its ticket ends it.
    @discardableResult
    public mutating func begin(_ id: Int, _ change: Change) -> Ticket {
        serial += 1
        entries[id] = Entry(serial: serial, change: change)
        return Ticket(id: id, serial: serial)
    }

    /// The server answered the change with `ticket`. True when it was the one standing in for
    /// its row; false when a newer change to the same row has taken over, and stays.
    @discardableResult
    public mutating func end(_ ticket: Ticket) -> Bool {
        guard let entry = entries[ticket.id], entry.serial == ticket.serial else { return false }
        entries.removeValue(forKey: ticket.id)
        return true
    }

    /// Whether an action on the row with `id` is still out.
    public func isPending(_ id: Int) -> Bool { entries[id] != nil }

    public var isEmpty: Bool { entries.isEmpty }

    /// The ids with a change out, for a caller that has to find each row.
    public var ids: Set<Int> { Set(entries.keys) }

    /// `rows` — a read of the list, or the list as shown — with the changes in flight laid
    /// over it. A removed row is left out; a replaced row stands in for the server's copy, or
    /// joins the list when the server does not list it yet and `admits` says it belongs
    /// (a restore from the trash on a board that hides the trash). A replaced row `admits`
    /// refuses is left out: it has moved off this list.
    public func overlay(_ rows: [SessionSummary], admits: (SessionSummary) -> Bool = { _ in true }) -> [SessionSummary] {
        guard !entries.isEmpty else { return rows }
        var result = rows
        for (id, entry) in entries {
            let index = result.firstIndex { $0.id == id }
            switch entry.change {
            case .removed:
                if let index { result.remove(at: index) }
            case var .replaced(row):
                if let index {
                    // A read's row knows more than the copy made here (its board row); the
                    // change rides on top of it rather than throwing that away.
                    if row.boardRow == nil { row.boardRow = result[index].boardRow }
                    if admits(row) { result[index] = row } else { result.remove(at: index) }
                } else if admits(row) {
                    result.append(row)
                }
            }
        }
        return result
    }
}
