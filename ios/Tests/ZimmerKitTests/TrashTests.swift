import XCTest
@testable import ZimmerKit

/// Trashing a session as the web UI's Trash does: outright over a turn in flight, asked first
/// over queued messages.
final class TrashTests: XCTestCase {
    private func client(_ handlers: [ScriptedTransport.Handler]) -> (ZimmerHTTPClient, ScriptedTransport) {
        let transport = ScriptedTransport(handlers)
        return (ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport), transport)
    }

    private func body(_ request: HTTPRequest) -> [String: Bool] {
        let object = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return (object ?? [:]).compactMapValues { $0 as? Bool }
    }

    private let trashed: ScriptedTransport.Handler = { _ in
        Fixtures.json(200, ["session": ["id": 9, "status": "archived"], "message": "Session moved to trash"])
    }

    func testATurnInFlightIsEndedInOneRequest() async throws {
        let (api, transport) = client([trashed])
        guard case let .trashed(session) = try await api.trash(9, force: false) else { return XCTFail("not trashed") }
        XCTAssertEqual(session.status, .archived)
        XCTAssertEqual(transport.sent.map(body), [["force": false, "end_turn": true]])
        XCTAssertEqual(transport.sent.first?.url.path, "/api/v1/sessions/9/archive")
    }

    func testAServerWithoutEndTurnSaysSoForAPerson() async throws {
        let (api, transport) = client([
            { _ in Fixtures.json(422, ["error": "A turn is in flight", "message": "You are not that session, so you cannot know"]) },
        ])
        do {
            _ = try await api.trash(9, force: false)
            XCTFail("expected a refusal")
        } catch let ZimmerError.http(_, message) {
            XCTAssertEqual(message, "A turn is in flight. Pause the session first, or trash it once the turn ends.")
        }
        XCTAssertEqual(transport.sent.count, 1, "never retried with force")
    }

    func testBulkTrashEndsTurnsToo() async throws {
        let (api, transport) = client([{ _ in Fixtures.json(200, ["archived_count": 2, "errors": []]) }])
        _ = try await api.bulkArchive([1, 2])
        let sent = transport.sent.first.flatMap { $0.body }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        XCTAssertEqual(sent?["end_turn"] as? Bool, true)
    }

    func testQueuedMessagesAreAskedAboutAndForceSendsThem() async throws {
        let (api, transport) = client([
            { _ in Fixtures.json(422, ["error": "Queued messages would be discarded", "message": "Cannot archive session 9: 2 queued messages"]) },
            trashed,
        ])
        let first = try await api.trash(9, force: false)
        XCTAssertEqual(first, .queued)
        XCTAssertEqual(transport.sent.count, 1, "nothing is discarded without asking")
        guard case .trashed = try await api.trash(9, force: true) else { return XCTFail("not trashed") }
        XCTAssertEqual(transport.sent.map { body($0)["force"] }, [false, true])
    }

    func testAnyOtherRefusalIsTheServersMessage() async throws {
        let (api, _) = client([
            { _ in Fixtures.json(422, ["error": "Cannot trash", "message": "Session cannot be trashed from current status: archived"]) },
        ])
        do {
            _ = try await api.trash(9, force: false)
            XCTFail("expected a refusal")
        } catch let ZimmerError.http(status, message) {
            XCTAssertEqual(status, 422)
            XCTAssertEqual(message, "Session cannot be trashed from current status: archived")
        }
    }

    func testTheFakeTrashesARunningSessionAndAsksAboutAQueue() async throws {
        let fake = FakeZimmerAPI()
        let first = try await fake.trash(1042, force: false)
        XCTAssertEqual(first, .queued)
        guard case let .trashed(session) = try await fake.trash(1042, force: true) else { return XCTFail("not trashed") }
        XCTAssertEqual(session.status, .archived)
    }

    func testTheFakeTrashesASessionElsewhereWhenTheInboxIsRead() async throws {
        let fake = FakeZimmerAPI(trashedElsewhere: 1035)
        let before = try await fake.sessions(.default, board: .onBoard, view: .lastTouched).sessions
        XCTAssertTrue(before.contains { $0.id == 1035 })
        _ = try await fake.notifications()
        let after = try await fake.sessions(.default, board: .onBoard, view: .lastTouched).sessions
        XCTAssertFalse(after.contains { $0.id == 1035 }, "the server no longer lists it")
    }
}
