import XCTest
@testable import ZimmerKit

/// The session page's and the board's small controls: the heartbeat's interval, a custom
/// snooze, when a trashed session goes for good, and what is asked before a restart.
final class SessionControlsTests: XCTestCase {
    private func client(_ handlers: [ScriptedTransport.Handler]) -> (ZimmerHTTPClient, ScriptedTransport) {
        let transport = ScriptedTransport(handlers)
        return (ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport), transport)
    }

    private func body(_ request: HTTPRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])
    }

    private func decode(_ json: [String: Any]) throws -> SessionSummary {
        try ZimmerJSON.decoder.decode(SessionSummary.self, from: JSONSerialization.data(withJSONObject: json))
    }

    // MARK: - Heartbeat

    func testTheIntervalIsReadAndChangedWithoutTouchingOnOrOff() async throws {
        let (api, transport) = client([{ _ in Fixtures.json(200, [
            "session": ["id": 5, "status": "needs_input", "heartbeat_enabled": false, "heartbeat_interval_seconds": 300],
            "heartbeat_enabled": false, "heartbeat_interval_seconds": 300,
        ]) }])

        let session = try await api.setHeartbeatInterval(5, seconds: 300)

        XCTAssertEqual("\(transport.sent[0].method) \(transport.sent[0].url.path)", "PATCH /api/v1/sessions/5/heartbeat")
        let sent = try body(transport.sent[0])
        XCTAssertEqual(sent["interval_seconds"] as? Int, 300)
        XCTAssertNil(sent["enabled"], "changing the interval leaves the heartbeat on or off, as the web popout's select does")
        XCTAssertEqual(session.heartbeatIntervalSeconds, 300)
        XCTAssertEqual(session.heartbeatEnabled, false)
    }

    func testTheIntervalOptionsAreTheWebPopoutsAndAnyOtherIsStillNamed() throws {
        XCTAssertEqual(HeartbeatInterval.options.map(\.seconds), [30, 60, 120, 300, 600, 900, 1800, 3600])
        XCTAssertEqual(HeartbeatInterval.options.map(\.label).first, "30 seconds")
        XCTAssertEqual(HeartbeatInterval.label(for: 3600), "1 hour")
        XCTAssertEqual(HeartbeatInterval.label(for: 7200), "2 hours", "the API and MCP take intervals the popout does not offer")
        XCTAssertEqual(HeartbeatInterval.label(for: 240), "4 minutes")
        XCTAssertEqual(HeartbeatInterval.label(for: 45), "45 seconds")
        XCTAssertEqual(try decode(["id": 1, "status": "running"]).heartbeatInterval, 60, "absent reads as the server's default")
        XCTAssertEqual(HeartbeatInterval.choices(including: 300), HeartbeatInterval.options)
        XCTAssertEqual(HeartbeatInterval.choices(including: 7200).map(\.seconds).suffix(2), [3600, 7200],
                       "an interval set elsewhere is offered in its place, so the picker shows what is set")
    }

    func testTheFixtureRefusesAnIntervalTheServerWould() async throws {
        let fake = FakeZimmerAPI()
        let changed = try await fake.setHeartbeatInterval(1038, seconds: 900)
        XCTAssertEqual(changed.heartbeatInterval, 900)
        do {
            _ = try await fake.setHeartbeatInterval(1038, seconds: 5)
            XCTFail("expected a refusal")
        } catch let ZimmerError.http(status, _) {
            XCTAssertEqual(status, 422)
        }
    }

    // MARK: - Custom snooze

    func testACustomSnoozeIsSentAsAnyOtherSnooze() async throws {
        let (api, transport) = client([{ _ in Fixtures.json(200, ["session": ["id": 5, "status": "needs_input", "visibility": "snoozed"]]) }])
        let until = Date(timeIntervalSince1970: 1_791_900_000) // 2026-10-13T14:00:00Z

        _ = try await api.setVisibility(5, .snoozed(until: until))

        XCTAssertEqual(try body(transport.sent[0]) as? [String: String],
                       ["visibility": "snoozed", "snoozed_until": "2026-10-13T14:00:00", "timezone": "UTC"])
    }

    func testTheEarliestCustomSnoozeIsTheNextWholeMinute() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_791_900_000 + 25) // 14:00:25
        XCTAssertEqual(VisibilityChange.earliestCustomSnooze(now: now, calendar: calendar),
                       Date(timeIntervalSince1970: 1_791_900_060), "14:01:00, as the web picker's min")
    }

    // MARK: - Trash expiry

    func testATrashedSessionSaysWhenItGoesForGood() throws {
        let now = Date(timeIntervalSince1970: 1_791_900_000)
        let trashed = try decode(["id": 1, "status": "archived", "trash_after": "2026-10-16T14:00:00Z"])
        XCTAssertEqual(trashed.trashExpiry(now: now), .on(Date(timeIntervalSince1970: 1_791_900_000 + 3 * 86_400)))
        XCTAssertEqual(trashed.trashExpiry(now: now.addingTimeInterval(4 * 86_400)), .pending, "past its date and not yet emptied")
        XCTAssertNil(try decode(["id": 1, "status": "archived"]).trashExpiry(now: now), "nothing held for a restore")
        XCTAssertNil(try decode(["id": 1, "status": "needs_input", "trash_after": "2026-10-16T14:00:00Z"]).trashExpiry(now: now),
                     "shown only in the trash, as the web header shows it")
    }

    func testTheFixtureHoldsATrashedSessionForFourDays() async throws {
        let fake = FakeZimmerAPI()
        let trashed = try await fake.archive(1035)
        let expiry = try XCTUnwrap(trashed.trashAfter)
        XCTAssertEqual(expiry.timeIntervalSinceNow, 4 * 86_400, accuracy: 60)
        let restored = try await fake.unarchive(1035)
        XCTAssertNil(restored.trashAfter)
    }

    // MARK: - Restart confirmation

    func testRestartingAFailedSessionAsksNothing() throws {
        XCTAssertNil(try decode(["id": 1, "status": "failed", "session_id": "abc"]).restartConfirmation)
    }

    func testRestartingAPausedSessionSaysItTakesItOver() throws {
        let paused = try decode(["id": 1, "status": "needs_input", "session_id": "abc", "metadata": ["clone_path": "/clones/1"]])
        XCTAssertEqual(paused.restartConfirmation,
                       "This session is paused, not failed. Restarting takes it over and sends an automated \"continue\" prompt into its existing conversation. Restart it?")
    }

    func testASessionWhoseTurnDiedBeforeItsPromptIsToldItsPromptGoesAgain() throws {
        let session = try decode([
            "id": 1, "status": "needs_input", "session_id": "abc", "prompt": "Do the thing",
            "metadata": ["clone_path": "/clones/1", "failure_reason": "spawn_failed"],
        ])
        XCTAssertEqual(session.restartConfirmation,
                       "This session's turn died before its prompt was ever delivered. Restarting takes it over and sends that original prompt again, into a freshly spawned runtime. Restart it?")
    }

    func testASessionWhoseSetupNeverFinishedIsToldItStartsOver() throws {
        let fromScratch = "There is no conversation to continue here — this session's setup never finished. Restarting throws away whatever was set up for it and re-runs the whole pipeline — a fresh clone, a fresh process — with its original prompt. Restart it?"
        let noClone = try decode([
            "id": 1, "status": "needs_input", "session_id": "abc", "prompt": "Do the thing",
            "metadata": ["failure_reason": "git_clone_failed"],
        ])
        XCTAssertEqual(noClone.restartConfirmation, fromScratch)
        let neverLaunched = try decode(["id": 1, "status": "needs_input", "metadata": ["clone_path": "/clones/1"]])
        XCTAssertEqual(neverLaunched.restartConfirmation, fromScratch)
    }

    func testTheFixturesPausedSessionsAreRestartedAsTakeovers() async throws {
        let session = try await FakeZimmerAPI().session(1038).session
        XCTAssertEqual(session.restartConfirmation?.hasPrefix("This session is paused, not failed."), true)
    }
}
