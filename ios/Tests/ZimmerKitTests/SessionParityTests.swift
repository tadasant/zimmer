import XCTest
@testable import ZimmerKit

/// The web UI's session actions, from the phone: what each sends, what the app reads back,
/// and the rules the in-memory fixture holds to.
final class SessionParityTests: XCTestCase {
    private func client(_ handlers: [ScriptedTransport.Handler]) -> (ZimmerHTTPClient, ScriptedTransport) {
        let transport = ScriptedTransport(handlers)
        return (ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport), transport)
    }

    private func body(_ request: HTTPRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])
    }

    private func session(_ id: Int, _ extra: [String: Any] = [:]) -> [String: Any] {
        ["session": ["id": id, "status": "needs_input"].merging(extra) { _, new in new }]
    }

    // MARK: - Reading a session

    func testTheRowReadsWhatTheWebUIsCardShows() throws {
        let json: [String: Any] = [
            "id": 1038, "status": "needs_input", "title": "Merge?",
            "goal": "PR open, CI green", "session_notes": "ask about the flag", "favorited": true,
            "visibility": "snoozed", "effective_visibility": "visible", "snoozed_until": "2026-10-09T09:00:00Z",
            "priority_class": "priority", "precedence": 12,
            "config": ["model": "opus", "max_turns": 50],
            "effort": ["level": "high", "source": "default", "default": "high", "levels": ["low", "high"]],
            "metadata": ["agent_root_key": "zimmer", "anything": ["nested": true]],
            "custom_metadata": [
                "github_pull_request_urls": ["https://github.com/tadasant/zimmer/pull/1261", "javascript:alert(1)"],
                "github_pull_request_statuses": ["https://github.com/tadasant/zimmer/pull/1261": "merged"],
                "github_pull_request_ci_statuses": ["https://github.com/tadasant/zimmer/pull/1261": "pass"],
            ],
        ]
        let row = try ZimmerJSON.decoder.decode(SessionSummary.self, from: JSONSerialization.data(withJSONObject: json))

        XCTAssertEqual(row.goal, "PR open, CI green")
        XCTAssertTrue(row.hasNotes)
        XCTAssertTrue(row.isFavorite)
        XCTAssertEqual(row.visibility, .snoozed)
        XCTAssertEqual(row.boardVisibility, .visible, "an expired snooze reads as visible, as the board draws it")
        XCTAssertEqual(row.model, "opus")
        XCTAssertEqual(row.effort?.levels, ["low", "high"])
        XCTAssertFalse(row.effort?.isExplicit ?? true)
        XCTAssertEqual(row.agentRoot, "zimmer")
        XCTAssertEqual(row.pullRequests.map(\.label), ["#1261"], "only https links become buttons")
        XCTAssertEqual(row.pullRequests.first?.state, "merged")
        XCTAssertEqual(row.pullRequests.first?.ci, "pass", "the evaluator's own words: pass, fail, pending, skipping, cancel")
    }

    func testFreeFormObjectsThatChangeShapeBlankAFieldNotTheList() throws {
        let json: [String: Any] = [
            "sessions": [
                ["id": 1, "status": "running", "config": ["model": 7], "effort": "high",
                 "metadata": [], "custom_metadata": ["github_pull_request_urls": "not-a-list"]],
                ["id": 2, "status": "needs_input", "visibility": "something_new"],
            ],
        ]
        let rows = try ZimmerJSON.decoder.decode(SessionListResponse.self, from: JSONSerialization.data(withJSONObject: json)).sessions

        XCTAssertEqual(rows.map(\.id), [1, 2])
        XCTAssertNil(rows[0].model)
        XCTAssertNil(rows[0].effort?.level)
        XCTAssertEqual(rows[0].pullRequests, [])
        XCTAssertEqual(rows[1].visibility, .visible, "an unknown visibility is drawn as on the board")
    }

    // MARK: - What each action sends

    func testTheBoardFilterAndSearchSendTheWebUIsParameters() async throws {
        let (api, transport) = client([
            { _ in Fixtures.json(200, ["sessions": []]) },
            { _ in Fixtures.json(200, ["sessions": []]) },
            { _ in Fixtures.json(200, ["sessions": [], "content_scan": ["complete": false, "timed_out": true, "next_cursor": "abc"]]) },
        ])

        _ = try await api.sessions(.needsInput, board: .onBoard)
        _ = try await api.sessions(.active, board: .all)
        let partial = try await api.search("deploy key", contents: true, filter: .failed, board: .offBoard)

        let queries = transport.sent.map { request in
            Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        }
        XCTAssertEqual(queries[0], ["status": "needs_input", "per_page": "100", "visibility": "on_board"])
        XCTAssertEqual(queries[1], ["per_page": "100"], "Both sends no visibility, which the server reads as unfiltered")
        XCTAssertEqual(transport.sent[2].url.path, "/api/v1/sessions/search")
        XCTAssertEqual(queries[2], ["q": "deploy key", "search_contents": "true", "status": "failed", "per_page": "100", "visibility": "off_board"])
        XCTAssertFalse(partial.complete, "a scan that stopped early is not a \"no match\"")
    }

    func testEachSessionActionHitsItsRoute() async throws {
        let ok: ScriptedTransport.Handler = { _ in Fixtures.json(200, ["session": ["id": 5, "status": "running"], "message": "ok"]) }
        let (api, transport) = client(Array(repeating: ok, count: 11))

        _ = try await api.unarchive(5)
        _ = try await api.restart(5)
        _ = try await api.pause(5)
        _ = try await api.toggleFavorite(5)
        _ = try await api.setVisibility(5, .hidden)
        _ = try await api.updateNotes(5, notes: "n")
        _ = try await api.rename(5, title: "t")
        _ = try await api.updateGoal(5, goal: "g")
        _ = try await api.updateEffort(5, effort: nil)
        _ = try await api.regenerateStatusSummary(5)
        _ = try await api.refreshTranscript(5)

        XCTAssertEqual(transport.sent.map { "\($0.method) \($0.url.path)" }, [
            "POST /api/v1/sessions/5/unarchive",
            "POST /api/v1/sessions/5/restart",
            "POST /api/v1/sessions/5/pause",
            "POST /api/v1/sessions/5/toggle_favorite",
            "PATCH /api/v1/sessions/5/visibility",
            "PATCH /api/v1/sessions/5/notes",
            "PATCH /api/v1/sessions/5",
            "PATCH /api/v1/sessions/5",
            "PATCH /api/v1/sessions/5/effort",
            "POST /api/v1/sessions/5/regenerate_status_summary",
            "POST /api/v1/sessions/5/refresh",
        ])
        XCTAssertEqual(try body(transport.sent[4]) as? [String: String], ["visibility": "hidden"])
        XCTAssertEqual(try body(transport.sent[5]) as? [String: String], ["session_notes": "n"])
        XCTAssertEqual(try body(transport.sent[6]) as? [String: String], ["title": "t"])
        XCTAssertEqual(try body(transport.sent[7]) as? [String: String], ["goal": "g"])
        XCTAssertEqual(try body(transport.sent[8]) as? [String: String], ["effort": "default"], "nil clears to the model's default")
    }

    func testPromoteDemoteAndHeartbeatSendTheRankedViewsWrites() async throws {
        let ok: ScriptedTransport.Handler = { _ in Fixtures.json(200, ["session": ["id": 5, "status": "waiting", "priority_class": "spot", "heartbeat_enabled": true]]) }
        let refusedStart: ScriptedTransport.Handler = { _ in Fixtures.json(200, [
            "session": ["id": 5, "status": "waiting", "priority_class": "priority"],
            "start": ["outcome": "refused", "message": "Session 5 is asleep on a wake."],
        ]) }
        let (api, transport) = client([refusedStart, ok, ok])

        let promoted = try await api.setSchedulingClass(5, priority: true)
        let demoted = try await api.setSchedulingClass(5, priority: false).session
        _ = try await api.setHeartbeat(5, enabled: false)

        XCTAssertEqual(transport.sent.map { "\($0.method) \($0.url.path)" }, [
            "PATCH /api/v1/sessions/5", "PATCH /api/v1/sessions/5", "PATCH /api/v1/sessions/5/heartbeat",
        ])
        XCTAssertEqual(try body(transport.sent[0]) as? [String: String], ["scheduling_class": "priority"])
        XCTAssertEqual(try body(transport.sent[1]) as? [String: String], ["scheduling_class": "spot", "place": "top_of_spot"],
                       "a demoted session goes to the head of the spot queue, as the Ranked view's button puts it")
        XCTAssertEqual(try body(transport.sent[2])["enabled"] as? Bool, false)
        XCTAssertEqual(promoted.startOutcome, "refused", "a start the promotion could not make is reported, not swallowed")
        XCTAssertEqual(promoted.startMessage, "Session 5 is asleep on a wake.")
        XCTAssertFalse(demoted.isPriority)
        XCTAssertEqual(demoted.heartbeatEnabled, true)
    }

    func testSendNowIsAForcedFollowUp() async throws {
        let (api, transport) = client([{ _ in Fixtures.json(200, ["session": ["id": 1, "status": "running"], "message": "Follow-up prompt sent immediately"]) }])

        let result = try await api.sendNow(1, prompt: "Stop and merge.")

        XCTAssertEqual(transport.sent[0].url.path, "/api/v1/sessions/1/follow_up")
        let sent = try body(transport.sent[0])
        XCTAssertEqual(sent["prompt"] as? String, "Stop and merge.")
        XCTAssertEqual(sent["force_immediate"] as? Bool, true)
        XCTAssertFalse(result.queued)
    }

    func testARefusalCarriesTheServersSentence() async throws {
        let (api, _) = client([{ _ in Fixtures.json(422, ["error": "Cannot pause", "message": "Session is not running"]) }])
        do {
            _ = try await api.pause(1)
            XCTFail("expected a refusal")
        } catch let error as ZimmerError {
            XCTAssertEqual(error, .http(status: 422, message: "Session is not running"))
        }
    }

    // MARK: - Snoozing

    func testASnoozeIsWrittenAsUTCWallClock() {
        let until = Date(timeIntervalSince1970: 1_791_712_800) // 2026-10-11T10:00:00Z
        XCTAssertEqual(VisibilityChange.snoozed(until: until).body,
                       ["visibility": "snoozed", "snoozed_until": "2026-10-11T10:00:00", "timezone": "UTC"])
    }

    func testTheSnoozePresetsMatchTheWebUIs() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
        }

        // Wednesday 2026-10-07, 14:30 local.
        let wednesday = VisibilityChange.snoozePresets(now: at(2026, 10, 7, 14, 30), calendar: calendar)
        XCTAssertEqual(wednesday.map(\.id), ["later_today", "tomorrow", "in_3_days", "this_weekend", "next_week"])
        XCTAssertEqual(wednesday.map(\.until), [
            at(2026, 10, 7, 17, 30), at(2026, 10, 8, 9), at(2026, 10, 10, 9), at(2026, 10, 10, 9), at(2026, 10, 12, 9),
        ])

        // On a Saturday "this weekend" is next Saturday; on a Monday "next week" is a week out.
        let saturday = VisibilityChange.snoozePresets(now: at(2026, 10, 10, 8), calendar: calendar)
        XCTAssertEqual(saturday.first { $0.id == "this_weekend" }?.until, at(2026, 10, 17, 9))
        let monday = VisibilityChange.snoozePresets(now: at(2026, 10, 12, 8), calendar: calendar)
        XCTAssertEqual(monday.first { $0.id == "next_week" }?.until, at(2026, 10, 19, 9))
    }

    // MARK: - The fixture

    func testTheFixtureKeepsSnoozedSessionsOffTheBoard() async throws {
        let fake = FakeZimmerAPI()
        let onBoard = try await fake.sessions(.active, board: .onBoard).map(\.id)
        let offBoard = try await fake.sessions(.active, board: .offBoard).map(\.id)
        XCTAssertFalse(onBoard.contains(1029))
        XCTAssertEqual(offBoard, [1029])

        _ = try await fake.setVisibility(1029, .visible)
        let afterwards = try await fake.sessions(.active, board: .onBoard).map(\.id)
        XCTAssertTrue(afterwards.contains(1029))
    }

    func testTheFixtureRefusesWhatTheServerRefuses() async throws {
        let fake = FakeZimmerAPI()
        await XCTAssertThrowsAsync(try await fake.pause(1038), "only a running session pauses")
        await XCTAssertThrowsAsync(try await fake.unarchive(1038), "only a trashed session is restored")
        await XCTAssertThrowsAsync(try await fake.updateEffort(1038, effort: "ludicrous"), "only the model's levels")
        await XCTAssertThrowsAsync(try await fake.setVisibility(1038, .snoozed(until: Date().addingTimeInterval(-60))), "a snooze is in the future")

        let restored = try await fake.unarchive(1019)
        XCTAssertEqual(restored.status, .needsInput)
        let starred = try await fake.toggleFavorite(1035)
        XCTAssertTrue(starred.isFavorite)
        await XCTAssertThrowsAsync(try await fake.rename(1035, title: "  "), "the server refuses a blank title")
        let restarted = try await fake.restart(1035)
        XCTAssertEqual(restarted.status, .waiting, "a restart hands the turn over; it has not started yet")
        let sentNow = try await fake.sendNow(1042, prompt: "Stop.")
        XCTAssertFalse(sentNow.queued, "Send now delivers even mid-turn")
    }

    func testSearchMatchesTitlesAndOnlyWhenAskedTranscripts() async throws {
        let fake = FakeZimmerAPI()
        let byTitle = try await fake.search("postgres", contents: false, filter: .active, board: .all).sessions.map(\.id)
        XCTAssertEqual(byTitle, [1035])
        let notInTitles = try await fake.search("ci is green", contents: false, filter: .active, board: .all).sessions
        XCTAssertEqual(notInTitles, [])
        let inTranscripts = try await fake.search("every check is green", contents: true, filter: .active, board: .all).sessions.map(\.id)
        XCTAssertEqual(inTranscripts, [1038])
    }
}

func XCTAssertThrowsAsync<T>(_ expression: @autoclosure () async throws -> T, _ message: String, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("expected an error: \(message)", file: file, line: line)
    } catch {}
}
