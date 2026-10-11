import Foundation

/// Everything else a person does to a session from the web UI's session page and its
/// mobile action menu: restore, restart, pause, star, hide or snooze, rename, goal, notes,
/// effort, scheduling class, heartbeat, and the two refreshes. Plus the board's visibility filter, search, and "Send now".
///
/// Every route here is on `Api::V1::SessionsController`, which the app's token already
/// reaches (`accepts_native_app_tokens`), so none of it widens what a phone can do on the
/// server: these are calls the app could already make, now with screens.
public protocol SessionActionsAPI: Sendable {
    /// The list, narrowed by board visibility as the web UI's board is: the newest
    /// `SessionFilter.maxPages` pages, with `complete` false when there were more.
    func sessions(_ filter: SessionFilter, board: BoardFilter) async throws -> SessionSearchResult
    /// Sessions matching `query` (the web UI's search box) within the same filters; with
    /// `contents`, transcripts are searched too — one bounded scan, its first page.
    func search(_ query: String, contents: Bool, filter: SessionFilter, board: BoardFilter) async throws -> SessionSearchResult
    /// Deliver now, ending the turn in flight — the web UI's "Send Now".
    func sendNow(_ id: Int, prompt: String) async throws -> FollowUpResult
    /// Restore from the trash.
    func unarchive(_ id: Int) async throws -> SessionSummary
    func restart(_ id: Int) async throws -> SessionSummary
    func pause(_ id: Int) async throws -> SessionSummary
    func toggleFavorite(_ id: Int) async throws -> SessionSummary
    func setVisibility(_ id: Int, _ change: VisibilityChange) async throws -> SessionSummary
    func updateNotes(_ id: Int, notes: String) async throws -> SessionSummary
    /// Rename. The server refuses a blank title.
    func rename(_ id: Int, title: String) async throws -> SessionSummary
    /// Set or clear (blank) the session's goal.
    func updateGoal(_ id: Int, goal: String) async throws -> SessionSummary
    /// Set the reasoning effort, or nil for the model's default.
    func updateEffort(_ id: Int, effort: String?) async throws -> SessionSummary
    /// The Ranked view's Promote to priority (which starts a waiting session) and Demote to
    /// spot (which lands it at the head of the spot queue).
    func setSchedulingClass(_ id: Int, priority: Bool) async throws -> SchedulingChange
    /// Turn the session's heartbeat on or off, at the interval it already has.
    func setHeartbeat(_ id: Int, enabled: Bool) async throws -> SessionSummary
    /// Ask for a fresh "where things stand"; it is written in the background.
    func regenerateStatusSummary(_ id: Int) async throws -> String
    /// Re-read the transcript from disk (the web UI's "Refresh Transcript").
    func refreshTranscript(_ id: Int) async throws -> String
    /// The whole transcript as plain text — what the web UI's "Copy full transcript" copies.
    func transcriptText(_ id: Int) async throws -> String
    /// Trash several at once. Refusals (a turn in flight, queued messages) are reported per
    /// session and do not stop the rest.
    func bulkArchive(_ ids: [Int]) async throws -> BulkArchiveResult
    /// "Refresh all" over the REST API: re-read transcripts, restart failed sessions, and
    /// continue sessions waiting on you that you did not pause — up to 50 of those together.
    func refreshAll() async throws -> String
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
    /// Up to `SessionFilter.maxPages` pages of the newest sessions — the first, then the rest
    /// at once — for the board views to order on the phone. `complete` is false when the
    /// filter matched more than that, and the list says so.
    public func sessions(_ filter: SessionFilter, board: BoardFilter) async throws -> SessionSearchResult {
        let base = filter.query.merging(board.query) { a, _ in a }
        let first: SessionListResponse = try await get("/api/v1/sessions", query: base.merging(["page": "1"]) { _, new in new })
        let pages = first.pagination?.total_pages ?? 1
        var rest: [Int: [SessionSummary]] = [:]
        if pages > 1 {
            try await withThrowingTaskGroup(of: (Int, [SessionSummary]).self) { group in
                for page in 2...min(pages, SessionFilter.maxPages) {
                    group.addTask {
                        let response: SessionListResponse = try await get("/api/v1/sessions", query: base.merging(["page": String(page)]) { _, new in new })
                        return (page, response.sessions)
                    }
                }
                for try await (page, rows) in group { rest[page] = rows }
            }
        }
        // A session created between two requests shifts a row onto the next page; it is shown once.
        var seen = Set<Int>()
        let rows = (first.sessions + rest.keys.sorted().flatMap { rest[$0] ?? [] }).filter { seen.insert($0.id).inserted }
        return SessionSearchResult(sessions: rows, complete: pages <= SessionFilter.maxPages)
    }

    public func search(_ query: String, contents: Bool, filter: SessionFilter, board: BoardFilter) async throws -> SessionSearchResult {
        var params = filter.query.merging(board.query) { a, _ in a }
        params["q"] = query
        if contents { params["search_contents"] = "true" }
        let response: SearchResponse = try await get("/api/v1/sessions/search", query: params)
        return SessionSearchResult(sessions: SessionOrdering.sorted(response.sessions), complete: response.content_scan?.complete ?? true)
    }

    public func sendNow(_ id: Int, prompt: String) async throws -> FollowUpResult {
        let segment = ZimmerPathComponent(String(id))
        let response: FollowUpResponse = try await post("/api/v1/sessions/\(segment)/follow_up", json: ["prompt": prompt, "force_immediate": true])
        return FollowUpResult(queued: false, message: response.message ?? "Sent now")
    }

    public func unarchive(_ id: Int) async throws -> SessionSummary {
        let segment = ZimmerPathComponent(String(id))
        return try await sessionAction("/api/v1/sessions/\(segment)/unarchive")
    }

    public func restart(_ id: Int) async throws -> SessionSummary {
        let segment = ZimmerPathComponent(String(id))
        return try await sessionAction("/api/v1/sessions/\(segment)/restart")
    }

    public func pause(_ id: Int) async throws -> SessionSummary {
        let segment = ZimmerPathComponent(String(id))
        return try await sessionAction("/api/v1/sessions/\(segment)/pause")
    }

    public func toggleFavorite(_ id: Int) async throws -> SessionSummary {
        let segment = ZimmerPathComponent(String(id))
        return try await sessionAction("/api/v1/sessions/\(segment)/toggle_favorite")
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

    public func setSchedulingClass(_ id: Int, priority: Bool) async throws -> SchedulingChange {
        let segment = ZimmerPathComponent(String(id))
        let body = priority ? ["scheduling_class": "priority"] : ["scheduling_class": "spot", "place": "top_of_spot"]
        let response: SchedulingResponse = try await patch("/api/v1/sessions/\(segment)", json: body)
        return SchedulingChange(session: response.session, startOutcome: response.start?.outcome, startMessage: response.start?.message)
    }

    public func setHeartbeat(_ id: Int, enabled: Bool) async throws -> SessionSummary {
        let segment = ZimmerPathComponent(String(id))
        let response: SessionEnvelope = try await patch("/api/v1/sessions/\(segment)/heartbeat", json: ["enabled": enabled])
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

    public func transcriptText(_ id: Int) async throws -> String {
        let segment = ZimmerPathComponent(String(id))
        let response: TranscriptResponse = try await get("/api/v1/sessions/\(segment)/transcript")
        return response.transcript_text
    }

    public func bulkArchive(_ ids: [Int]) async throws -> BulkArchiveResult {
        let response: BulkArchiveResult = try await post("/api/v1/sessions/bulk_archive", json: ["session_ids": ids])
        return response
    }

    public func refreshAll() async throws -> String {
        let response: RefreshAllResponse = try await post("/api/v1/sessions/refresh_all", json: [:])
        return response.summary
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

/// What a search found. A transcript search is one bounded scan; `complete` is false when it
/// stopped before reading every candidate, so "nothing matched" is not yet the answer.
public struct SessionSearchResult: Hashable, Sendable {
    public var sessions: [SessionSummary]
    public var complete: Bool

    public init(sessions: [SessionSummary], complete: Bool = true) {
        self.sessions = sessions
        self.complete = complete
    }
}

/// A promotion or demotion, and — when promoting tried to start a waiting session — what the
/// server says came of that (`started`, or `refused` with the reason, e.g. asleep on a wake).
public struct SchedulingChange: Hashable, Sendable {
    public var session: SessionSummary
    public var startOutcome: String?
    public var startMessage: String?

    public init(session: SessionSummary, startOutcome: String? = nil, startMessage: String? = nil) {
        self.session = session
        self.startOutcome = startOutcome
        self.startMessage = startMessage
    }
}

struct SearchResponse: Decodable {
    struct ContentScan: Decodable { let complete: Bool? }
    let sessions: [SessionSummary]
    let content_scan: ContentScan?
}

struct SchedulingResponse: Decodable {
    struct Start: Decodable {
        let outcome: String?
        let message: String?
    }
    let session: SessionSummary
    let start: Start?
}

/// What a bulk trash did: how many went, and each refusal with the server's reason.
public struct BulkArchiveResult: Hashable, Sendable, Decodable {
    public struct Refusal: Hashable, Sendable, Decodable {
        public var id: Int
        public var message: String
    }

    public var archivedCount: Int
    public var errors: [Refusal]

    public init(archivedCount: Int, errors: [Refusal] = []) {
        self.archivedCount = archivedCount
        self.errors = errors
    }

    enum CodingKeys: String, CodingKey {
        case archivedCount = "archived_count"
        case errors
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        archivedCount = try container.decodeIfPresent(Int.self, forKey: .archivedCount) ?? 0
        errors = (try? container.decodeIfPresent([Refusal].self, forKey: .errors)) ?? []
    }
}

struct TranscriptResponse: Decodable {
    let transcript_text: String
}

struct RefreshAllResponse: Decodable {
    let message: String?
    let refreshed: Int?
    let restarted: Int?
    let continued: Int?
    let errors: Int?

    /// The counts, which say more than the server's "Refresh complete"; its sentence only when
    /// nothing was touched ("No non-archived sessions to refresh").
    var summary: String {
        let touched = (refreshed ?? 0) + (restarted ?? 0) + (continued ?? 0) + (errors ?? 0)
        if touched == 0, let message, !message.isEmpty { return message }
        var parts = ["Refreshed \(refreshed ?? 0)", "restarted \(restarted ?? 0)", "continued \(continued ?? 0)"]
        if let errors, errors > 0 { parts.append("\(errors) failed") }
        return parts.joined(separator: ", ")
    }
}

/// Any response whose `session` key is the API's one session shape.
struct SessionEnvelope: Decodable {
    let session: SessionSummary
}

struct MessageEnvelope: Decodable {
    let message: String?
}
