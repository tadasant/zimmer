import XCTest
@testable import ZimmerKit

/// Why a session is waiting, and what can be done about it: the banners `GET /sessions/:id`
/// sends, Force, and the messages that were never delivered.
final class WaitingTests: XCTestCase {
    private func client(_ handlers: [ScriptedTransport.Handler]) -> (ZimmerHTTPClient, ScriptedTransport) {
        let transport = ScriptedTransport(handlers)
        return (ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport), transport)
    }

    private func query(_ request: HTTPRequest) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    private func show(_ waiting: Any?) -> ScriptedTransport.Handler {
        var body: [String: Any] = ["session": ["id": 9, "status": "waiting"]]
        if let waiting { body["waiting"] = waiting }
        let response = Fixtures.json(200, body)
        return { _ in response }
    }

    func testBannersDecodeInOrderWithTheirActions() async throws {
        let (api, _) = client([show([
            "reasons": [
                ["mechanism": "spot_hold", "label": "the spot gate", "at": "2026-10-13T09:00:00Z", "current": false, "demoted": true],
                ["mechanism": "turn_queued", "label": "a worker thread", "at": "2026-10-13T09:05:00Z", "current": true, "demoted": false],
            ],
            "banners": [
                ["key": "spot_hold", "tone": "warning", "headline": "Held for quota headroom", "body": ["First.", NSNull(), "", "Second."], "details": ["overdue": false],
                 "action": ["kind": "update_scheduling_class", "label": "Make this session priority", "scheduling_class": "priority"]],
                ["key": "queued_turn", "tone": "info", "headline": "Queued for a worker", "body": ["Waiting."], "details": [:],
                 "action": ["kind": "force_start", "label": "Force", "expected_victim_id": 42, "confirm": "Stop session #42's turn?"]],
                ["key": "mcp_oauth_reconnect", "tone": "info", "headline": "Authorization complete", "body": [], "details": ["servers": ["Linear"]],
                 "action": ["kind": "follow_up", "label": "Reconnect now", "prompt": "Linear has been re-authorized."]],
                ["key": "mcp_oauth_required", "tone": "warning", "headline": "OAuth Authorization Required", "body": ["Authorize."], "details": [:],
                 "action": ["kind": "open_in_browser", "label": "Authorize in the browser", "path": "/sessions/9"]],
                ["key": "pending_wake", "tone": "info", "headline": "Asleep until Oct 14, 09:00 UTC", "body": ["It wakes on its own."], "details": [:], "action": NSNull()],
            ],
        ])])

        let waiting = try await api.session(9).waiting
        XCTAssertEqual(waiting.reasons.map(\.mechanism), ["spot_hold", "turn_queued"])
        XCTAssertEqual(waiting.reasons.first { $0.current }?.mechanism, "turn_queued")
        XCTAssertTrue(waiting.reasons[0].demoted)
        XCTAssertNotNil(waiting.reasons[0].at)

        XCTAssertEqual(waiting.banners.map(\.key), ["spot_hold", "queued_turn", "mcp_oauth_reconnect", "mcp_oauth_required", "pending_wake"], "the page's order")
        XCTAssertEqual(waiting.banners[0].tone, .warning)
        XCTAssertEqual(waiting.banners[0].body, ["First.", "Second."], "empty paragraphs are not drawn")
        XCTAssertEqual(waiting.banners[0].action, .updateSchedulingClass(label: "Make this session priority", priority: true))
        XCTAssertEqual(waiting.banners[1].tone, .info)
        XCTAssertEqual(waiting.banners[1].action, .forceStart(label: "Force", expectedVictimID: 42, confirm: "Stop session #42's turn?"))
        XCTAssertEqual(waiting.banners[2].action, .followUp(label: "Reconnect now", prompt: "Linear has been re-authorized."))
        XCTAssertEqual(waiting.banners[3].action, .openInBrowser(label: "Authorize in the browser", path: "/sessions/9"))
        XCTAssertNil(waiting.banners[4].action)
    }

    func testAnOlderServerWithoutWaitingHasNothingToSay() async throws {
        let (api, _) = client([show(nil), show("not an object")])
        let missing = try await api.session(9)
        XCTAssertEqual(missing.waiting, .empty)
        XCTAssertEqual(missing.session.id, 9, "the page still reads")
        let garbled = try await api.session(9)
        XCTAssertEqual(garbled.waiting, .empty)
    }

    func testAnUnknownActionIsNoControlAndAnUnknownBannerIsStillShown() async throws {
        let (api, _) = client([show(["banners": [
            ["key": "brand_new_banner", "tone": "ultraviolet", "headline": "Something new", "body": ["Said by the server."],
             "action": ["kind": "teleport", "label": "Teleport"]],
            // No victim: Force would stop a turn nobody was shown.
            ["key": "queued_turn", "tone": "info", "headline": "Queued for a worker", "action": ["kind": "force_start", "label": "Force"]],
            // A path off the web app is not opened.
            ["key": "mcp_oauth_required", "headline": "OAuth", "action": ["kind": "open_in_browser", "path": "https://elsewhere.example/x"]],
            ["key": "no_headline"],
            "not a banner",
        ]])])

        let banners = try await api.session(9).waiting.banners
        XCTAssertEqual(banners.map(\.key), ["brand_new_banner", "queued_turn", "mcp_oauth_required"], "an unreadable entry is dropped, not the list")
        XCTAssertEqual(banners[0].headline, "Something new")
        XCTAssertEqual(banners[0].tone, .warning, "an unknown tone reads as a warning")
        XCTAssertNil(banners[0].action)
        XCTAssertNil(banners[1].action)
        XCTAssertNil(banners[2].action)
    }

    func testForceStartSendsTheConfirmedVictimAndCarriesTheServersSentence() async throws {
        let (api, transport) = client([
            { _ in Fixtures.json(200, ["session": ["id": 9, "status": "waiting"], "message": "Session 42's turn was stopped and put back in the queue."]) },
            { _ in Fixtures.json(422, ["error": "Cannot force", "message": "The turn you confirmed — session 42's — is no longer the one that would be stopped."]) },
        ])

        let forced = try await api.forceStart(9, expectedVictimID: 42)
        XCTAssertEqual(forced.message, "Session 42's turn was stopped and put back in the queue.")
        XCTAssertEqual(forced.session.id, 9)
        XCTAssertEqual(transport.sent[0].method, "POST")
        XCTAssertEqual(transport.sent[0].url.path, "/api/v1/sessions/9/force_start")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: transport.sent[0].body ?? Data()) as? [String: Int])
        XCTAssertEqual(body, ["expected_victim_id": 42])

        do {
            _ = try await api.forceStart(9, expectedVictimID: 42)
            XCTFail("a refusal is an error")
        } catch let ZimmerError.http(status, message) {
            XCTAssertEqual(status, 422)
            XCTAssertEqual(message, "The turn you confirmed — session 42's — is no longer the one that would be stopped.", "the person reads the server's reason")
        }
    }

    func testUndeliveredMessagesAreAskedForByStatus() async throws {
        let (api, transport) = client([
            { _ in Fixtures.json(200, ["enqueued_messages": [
                ["id": 2, "content": "second", "position": 2, "status": "undelivered"],
                ["id": 1, "content": "first", "position": 1, "status": "undelivered", "origin": "automated_pr_poller"],
            ]]) },
        ])
        let messages = try await api.undeliveredMessages(9)
        XCTAssertEqual(transport.sent[0].url.path, "/api/v1/sessions/9/enqueued_messages")
        XCTAssertEqual(query(transport.sent[0])["status"], "undelivered")
        XCTAssertEqual(messages.map(\.id), [1, 2])
        XCTAssertFalse(messages[0].isPending)
    }

    func testTheFixtureHoldsTheSweepUntilItIsMadePriority() async throws {
        let fake = FakeZimmerAPI()
        let held = try await fake.session(1031).waiting.banners
        XCTAssertEqual(held.map(\.key), ["spot_hold"])
        XCTAssertEqual(held.first?.action, .updateSchedulingClass(label: "Make this session priority", priority: true))

        _ = try await fake.setSchedulingClass(1031, priority: true)
        let promoted = try await fake.session(1031)
        XCTAssertEqual(promoted.session.status, .running)
        XCTAssertTrue(promoted.waiting.banners.isEmpty, "a promoted session is no longer held")
    }

    func testTheFixtureForcesTheQueuedTurnOnlyOverTheConfirmedVictim() async throws {
        let fake = FakeZimmerAPI()
        let queued = try await fake.session(1029).waiting.banners
        let banner = try XCTUnwrap(queued.first { $0.key == "queued_turn" })
        guard case let .forceStart(_, victim, confirm)? = banner.action else { return XCTFail("Force is offered") }
        XCTAssertEqual(victim, 1042, "the running session")
        XCTAssertTrue(confirm.contains("#1042"))

        await XCTAssertThrowsAsync(try await fake.forceStart(1029, expectedVictimID: 1038), "not the turn that would be stopped")
        await XCTAssertThrowsAsync(try await fake.forceStart(1031, expectedVictimID: 1042), "nothing queued for a worker")
        let forced = try await fake.forceStart(1029, expectedVictimID: victim)
        XCTAssertEqual(forced.session.status, .running)
        let after = try await fake.session(1029)
        XCTAssertNil(after.waiting.banners.first { $0.key == "queued_turn" })
        let stopped = try await fake.session(1042)
        XCTAssertEqual(stopped.session.status, .waiting, "the stopped turn went back in the queue")
    }

    func testTheFixturesReconnectBannerGoesOnceAMessageReachesTheAgent() async throws {
        let fake = FakeZimmerAPI()
        let banners = try await fake.session(1035).waiting.banners
        let banner = try XCTUnwrap(banners.first)
        XCTAssertEqual(banner.key, "mcp_oauth_reconnect")
        guard case let .followUp(label, prompt)? = banner.action else { return XCTFail("a reconnect message is offered") }
        XCTAssertEqual(label, "Reconnect now")
        _ = try await fake.followUp(1035, prompt: prompt)
        let after = try await fake.session(1035).waiting.banners
        XCTAssertTrue(after.isEmpty)

        let retired = try await fake.undeliveredMessages(1035)
        XCTAssertEqual(retired.count, 1)
        let none = try await fake.undeliveredMessages(1038)
        XCTAssertTrue(none.isEmpty)
    }
}
