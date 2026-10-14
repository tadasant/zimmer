import XCTest
@testable import ZimmerKit

/// Opening a session reads as a person opening it, and its conversation reads back past the cap.
final class OpenSessionTests: XCTestCase {
    private func client(_ handlers: [ScriptedTransport.Handler]) -> (ZimmerHTTPClient, ScriptedTransport) {
        let transport = ScriptedTransport(handlers)
        return (ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport), transport)
    }

    private func query(_ request: HTTPRequest) -> [String: String] {
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testOpeningSaysViewedAndAPlainReadDoesNot() async throws {
        let show: ScriptedTransport.Handler = { _ in Fixtures.json(200, ["session": ["id": 9, "status": "needs_input"]]) }
        let (api, transport) = client([show, show])
        _ = try await api.openSession(9)
        _ = try await api.session(9)
        XCTAssertEqual(query(transport.sent[0])["viewed"], "true")
        XCTAssertNil(query(transport.sent[1])["viewed"])
    }

    func testTheConversationIsReadWholeAndEarlierPagesStartWhereTheServerSays() async throws {
        let (api, transport) = client([
            { _ in Fixtures.json(200, ["messages": [["role": "user", "content": "newest"]], "total": 250, "first_position": 249, "truncated": true]) },
            { _ in Fixtures.json(200, ["messages": [["role": "user", "content": "a"], ["role": "assistant", "content": "b"]], "total": 250, "first_position": 47, "truncated": true]) },
        ])
        let newest = try await api.conversation(9, limit: 1)
        XCTAssertEqual(query(transport.sent[0])["full_content"], "true")
        XCTAssertEqual(newest.firstPosition, 249)
        XCTAssertEqual(newest.messages.first?.id, 249)

        let earlier = try await api.earlierMessages(9, before: 49, limit: 2)
        XCTAssertEqual(query(transport.sent[1])["before"], "49")
        XCTAssertEqual(earlier.firstPosition, 47)
        XCTAssertEqual(earlier.messages.map(\.id), [47, 48], "ids are positions, so pages join without gaps or repeats")
    }

    func testAnOlderServerWithoutFirstPositionStillNumbersFromTheEnd() {
        let conversation = Conversation(messages: [ConversationMessage(id: 8, role: .user, content: "x")], total: 9)
        XCTAssertEqual(conversation.firstPosition, 8)
    }

    func testTheFakeMarksTheSessionsNotificationsReadOnOpenAndPagesBack() async throws {
        let api = FakeZimmerAPI()
        let before = try await api.unreadNotificationCount()
        _ = try await api.openSession(1038)
        let after = try await api.unreadNotificationCount()
        XCTAssertLessThan(after, before)

        let page = try await api.earlierMessages(1044, before: 3, limit: 2)
        XCTAssertEqual(page.firstPosition, 1)
        XCTAssertEqual(page.messages.count, 2)
    }
}
