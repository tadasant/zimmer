import XCTest
@testable import ZimmerKit

/// Trashing a session as the web UI's Trash does: outright over a turn in flight, asked first
/// over queued messages.
final class TrashTests: XCTestCase {
    private func client(_ handlers: [ScriptedTransport.Handler]) -> (ZimmerHTTPClient, ScriptedTransport) {
        let transport = ScriptedTransport(handlers)
        return (ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport), transport)
    }

    private func force(_ request: HTTPRequest) -> Bool? {
        let body = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return body?["force"] as? Bool
    }

    private let trashed: ScriptedTransport.Handler = { _ in
        Fixtures.json(200, ["session": ["id": 9, "status": "archived"], "message": "Session moved to trash"])
    }

    func testATurnInFlightIsTrashedOutright() async throws {
        let (api, transport) = client([
            { _ in Fixtures.json(422, ["error": "A turn is in flight", "message": "Cannot archive session 9: an agent turn is in flight"]) },
            trashed,
        ])
        guard case let .trashed(session) = try await api.trash(9, force: false) else { return XCTFail("not trashed") }
        XCTAssertEqual(session.status, .archived)
        XCTAssertEqual(transport.sent.map(force), [false, true])
        XCTAssertEqual(transport.sent.first?.url.path, "/api/v1/sessions/9/archive")
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
        XCTAssertEqual(transport.sent.map(force), [false, true])
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
}
