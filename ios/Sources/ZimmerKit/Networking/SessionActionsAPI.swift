import Foundation

/// Everything else a person does to a session from the web UI's session page and its
/// mobile action menu: restore, restart, pause, star, hide or snooze, rename, goal, notes,
/// effort, and the two refreshes. Plus the board's visibility filter, search, and "Send now".
///
/// Every route here is on `Api::V1::SessionsController`, which the app's token already
/// reaches (`accepts_native_app_tokens`), so none of it widens what a phone can do on the
/// server: these are calls the app could already make, now with screens.
public protocol SessionActionsAPI: Sendable {
    /// The list, narrowed by board visibility as the web UI's board is.
    func sessions(_ filter: SessionFilter, board: BoardFilter) async throws -> [SessionSummary]
    /// Sessions matching `query` (the web UI's search box) within the same filters; with
    /// `contents`, transcripts are searched too — one bounded scan, its first page.
    func search(_ query: String, contents: Bool, filter: SessionFilter, board: BoardFilter) async throws -> [SessionSummary]
    /// Deliver now, ending the turn in flight — the web UI's "Send Now".
    func sendNow(_ id: Int, prompt: String) async throws -> FollowUpResult
    /// Restore from the trash.
    func unarchive(_ id: Int) async throws -> SessionSummary
    func restart(_ id: Int) async throws -> SessionSummary
    func pause(_ id: Int) async throws -> SessionSummary
    func toggleFavorite(_ id: Int) async throws -> SessionSummary
    func setVisibility(_ id: Int, _ change: VisibilityChange) async throws -> SessionSummary
    func updateNotes(_ id: Int, notes: String) async throws -> SessionSummary
    /// Rename. A blank title clears it, and the web UI's fallback ("Session 123") shows.
    func rename(_ id: Int, title: String) async throws -> SessionSummary
    /// Set or clear (blank) the session's goal.
    func updateGoal(_ id: Int, goal: String) async throws -> SessionSummary
    /// Set the reasoning effort, or nil for the model's default.
    func updateEffort(_ id: Int, effort: String?) async throws -> SessionSummary
    /// Ask for a fresh "where things stand"; it is written in the background.
    func regenerateStatusSummary(_ id: Int) async throws -> String
    /// Re-read the transcript from disk (the web UI's "Refresh Transcript").
    func refreshTranscript(_ id: Int) async throws -> String
}

/// A board-visibility change: back on the board, hidden until shown again, or snoozed
/// until a time.
public enum VisibilityChange: Hashable, Sendable {
    case visible
    case hidden
    case snoozed(until: Date)

    /// The body of `PATCH /api/v1/sessions/:id/visibility`. `snoozed_until` is a naive
    /// wall-clock time read in `timezone`, so it is written in UTC and labelled UTC.
    public var body: [String: String] {
        switch self {
        case .visible: return ["visibility": "visible"]
        case .hidden: return ["visibility": "hidden"]
        case let .snoozed(until):
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            return ["visibility": "snoozed", "snoozed_until": formatter.string(from: until), "timezone": "UTC"]
        }
    }

    /// The web UI's snooze presets (`visibility_controller.js`), worked out from `now` in
    /// `calendar`'s time zone the way the browser works them out in its own: "Later today" is
    /// three hours on, and the rest land at 9 AM. "This weekend" is the coming Saturday — next
    /// Saturday once a weekend is under way — and "Next week" the next Monday strictly after today.
    public static func snoozePresets(now: Date = Date(), calendar: Calendar = .current) -> [SnoozePreset] {
        func nineAM(daysAhead: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: daysAhead, to: calendar.startOfDay(for: now)) ?? now
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
        }
        // `Calendar` numbers Sunday 1 … Saturday 7; the browser's `getDay()` Sunday 0 … Saturday 6.
        let day = calendar.component(.weekday, from: now) - 1
        let toSaturday = ((6 - day) + 7) % 7
        let toMonday = (8 - day) % 7
        return [
            SnoozePreset(id: "later_today", label: "Later today", until: now.addingTimeInterval(3 * 3600)),
            SnoozePreset(id: "tomorrow", label: "Tomorrow", until: nineAM(daysAhead: 1)),
            SnoozePreset(id: "in_3_days", label: "In 3 days", until: nineAM(daysAhead: 3)),
            SnoozePreset(id: "this_weekend", label: "This weekend", until: nineAM(daysAhead: toSaturday == 0 ? 7 : toSaturday)),
            SnoozePreset(id: "next_week", label: "Next week", until: nineAM(daysAhead: toMonday == 0 ? 7 : toMonday)),
        ]
    }
}

public struct SnoozePreset: Hashable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let until: Date
}

/// The board-visibility filter, as the web UI's filter form offers it. "On board" is its
/// default: hidden and snoozed sessions are tidied away, never stopped.
public enum BoardFilter: String, Hashable, Sendable, CaseIterable, Identifiable {
    case onBoard
    case offBoard
    case all

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .onBoard: return "On board"
        case .offBoard: return "Snoozed & hidden"
        case .all: return "Both"
        }
    }

    var query: [String: String] {
        switch self {
        case .onBoard: return ["visibility": "on_board"]
        case .offBoard: return ["visibility": "off_board"]
        case .all: return [:]
        }
    }

    /// Whether a session belongs on a list with this filter.
    public func admits(_ session: SessionSummary) -> Bool {
        switch self {
        case .onBoard: return session.boardVisibility == .visible
        case .offBoard: return session.boardVisibility != .visible
        case .all: return true
        }
    }
}

// `ZimmerHTTPClient: ZimmerAPI`, which refines `SessionActionsAPI`.
extension ZimmerHTTPClient {
    public func sessions(_ filter: SessionFilter, board: BoardFilter) async throws -> [SessionSummary] {
        let response: SessionListResponse = try await get("/api/v1/sessions", query: filter.query.merging(board.query) { a, _ in a })
        return SessionOrdering.sorted(response.sessions)
    }

    public func search(_ query: String, contents: Bool, filter: SessionFilter, board: BoardFilter) async throws -> [SessionSummary] {
        var params = filter.query.merging(board.query) { a, _ in a }
        params["q"] = query
        if contents { params["search_contents"] = "true" }
        let response: SessionListResponse = try await get("/api/v1/sessions/search", query: params)
        return SessionOrdering.sorted(response.sessions)
    }

    public func sendNow(_ id: Int, prompt: String) async throws -> FollowUpResult {
        let segment = ZimmerPathComponent(String(id))
        let response: FollowUpResponse = try await post("/api/v1/sessions/\(segment)/follow_up", json: ["prompt": prompt, "force_immediate": true])
        return FollowUpResult(queued: false, message: response.message ?? "Sent now")
    }

    public func unarchive(_ id: Int) async throws -> SessionSummary {
        try await sessionAction("/api/v1/sessions/\(ZimmerPathComponent(String(id)))/unarchive")
    }

    public func restart(_ id: Int) async throws -> SessionSummary {
        try await sessionAction("/api/v1/sessions/\(ZimmerPathComponent(String(id)))/restart")
    }

    public func pause(_ id: Int) async throws -> SessionSummary {
        try await sessionAction("/api/v1/sessions/\(ZimmerPathComponent(String(id)))/pause")
    }

    public func toggleFavorite(_ id: Int) async throws -> SessionSummary {
        try await sessionAction("/api/v1/sessions/\(ZimmerPathComponent(String(id)))/toggle_favorite")
    }

    public func setVisibility(_ id: Int, _ change: VisibilityChange) async throws -> SessionSummary {
        let segment = ZimmerPathComponent(String(id))
        let response: SessionEnvelope = try await patch("/api/v1/sessions/\(segment)/visibility", json: change.body)
        return response.session
    }

    public func updateNotes(_ id: Int, notes: String) async throws -> SessionSummary {
        let segment = ZimmerPathComponent(String(id))
        let response: SessionEnvelope = try await patch("/api/v1/sessions/\(segment)/notes", json: ["session_notes": notes])
        return response.session
    }

    public func rename(_ id: Int, title: String) async throws -> SessionSummary {
        let segment = ZimmerPathComponent(String(id))
        let response: SessionEnvelope = try await patch("/api/v1/sessions/\(segment)", json: ["title": title])
        return response.session
    }

    public func updateGoal(_ id: Int, goal: String) async throws -> SessionSummary {
        let segment = ZimmerPathComponent(String(id))
        let response: SessionEnvelope = try await patch("/api/v1/sessions/\(segment)", json: ["goal": goal])
        return response.session
    }

    public func updateEffort(_ id: Int, effort: String?) async throws -> SessionSummary {
        let segment = ZimmerPathComponent(String(id))
        let response: SessionEnvelope = try await patch("/api/v1/sessions/\(segment)/effort", json: ["effort": effort ?? "default"])
        return response.session
    }

    public func regenerateStatusSummary(_ id: Int) async throws -> String {
        let segment = ZimmerPathComponent(String(id))
        let response: MessageEnvelope = try await post("/api/v1/sessions/\(segment)/regenerate_status_summary", json: [:])
        return response.message ?? "Status summary regeneration queued"
    }

    public func refreshTranscript(_ id: Int) async throws -> String {
        let segment = ZimmerPathComponent(String(id))
        let response: MessageEnvelope = try await post("/api/v1/sessions/\(segment)/refresh", json: [:])
        return response.message ?? "Transcript refreshed"
    }

    // MARK: - Plumbing

    /// A `POST` with no body, answered with `{ session: … }`. Callers pass the whole path as
    /// a literal, which is what `native_app_api_coverage_test.rb` reads.
    private func sessionAction(_ path: String) async throws -> SessionSummary {
        let response: SessionEnvelope = try await post(path, json: [:])
        return response.session
    }

    func patch<T: Decodable>(_ path: String, json: [String: Any]) async throws -> T {
        let body = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        let response = try await perform(method: "PATCH", path: path, query: [:], body: body)
        do {
            return try ZimmerJSON.decoder.decode(T.self, from: response.body)
        } catch {
            throw ZimmerError.decoding("\(path): \(error)")
        }
    }
}

/// Any response whose `session` key is the API's one session shape.
struct SessionEnvelope: Decodable {
    let session: SessionSummary
}

struct MessageEnvelope: Decodable {
    let message: String?
}
