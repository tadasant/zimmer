import XCTest
@testable import ZimmerKit

/// The conversation as the page reads it: filtered by the web UI's levels, and widened by a
/// hundred at a time. How a message's markdown is cut into blocks is `MarkdownTests`.
final class TranscriptTests: XCTestCase {
    func testTheLevelsShowWhatTheWebUIsDo() {
        let words = ConversationMessage(id: 0, role: .assistant, content: "Done.", timestamp: nil)
        let tool = ConversationMessage(id: 1, role: .assistant, content: "Using tool: Bash", timestamp: nil, hasToolUse: true)
        let conversation = Conversation(messages: [words, tool])
        XCTAssertEqual(conversation.messages(at: .minimal).map(\.id), [0])
        XCTAssertEqual(conversation.messages(at: .condensed).map(\.id), [0, 1])
        XCTAssertEqual(conversation.messages(at: .verbose).map(\.id), [0, 1])
        XCTAssertTrue(ConversationLevel.condensed.foldsToolTraffic)
        XCTAssertFalse(ConversationLevel.verbose.foldsToolTraffic)
        XCTAssertEqual(ConversationLevel.allCases.map(\.label), ["Minimal", "Condensed", "Verbose"])
    }

    func testToolTrafficCondensesToTheToolAndWhatItWasGiven() {
        let use = ConversationMessage(id: 1, role: .assistant, content: "**Using tool: Bash**\n```\ngh pr checks 1261\n```", timestamp: nil, hasToolUse: true)
        XCTAssertEqual(use.condensedLine, "Using tool: Bash · gh pr checks 1261")
        let result = ConversationMessage(id: 2, role: .assistant, content: "**Tool Result:**\n```\n✓ ios pass\n✓ lint pass\n```", timestamp: nil, hasToolResult: true)
        XCTAssertEqual(result.condensedLine, "Tool Result: · ✓ ios pass")
        let mixed = ConversationMessage(id: 3, role: .assistant, content: "Checking now.\n**Using tool: Bash**\n```\nls\n```", timestamp: nil, hasToolUse: true)
        XCTAssertEqual(mixed.condensedLine, "Using tool: Bash · ls", "the tool, not the words before it")
        XCTAssertEqual(ConversationMessage(id: 4, role: .assistant, content: "Using tool: Bash\nls", timestamp: nil, hasToolUse: true).condensedLine, "Using tool: Bash · ls")
        XCTAssertEqual(ConversationMessage(id: 5, role: .assistant, content: "", timestamp: nil, hasToolUse: true).condensedLine, "")
    }

    func testTheReadSendsItsLimitAndTheFixtureWindowsLikeTheServer() async throws {
        let transport = ScriptedTransport([{ _ in Fixtures.json(200, ["messages": [], "total": 0, "truncated": false]) }])
        let api = ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport)
        _ = try await api.conversation(7, limit: 200)
        XCTAssertEqual(transport.sent.first?.url.query, "full_content=true&limit=200")

        let fake = FakeZimmerAPI()
        let two = try await fake.conversation(1044, limit: 2)
        XCTAssertEqual(two.messages.map(\.id), [5, 6], "the newest two, positions from the start")
        XCTAssertEqual(two.total, 7)
        XCTAssertTrue(two.truncated)
        let all = try await fake.conversation(1044)
        XCTAssertEqual(all.messages.count, 7)
        XCTAssertFalse(all.truncated)
    }
}
