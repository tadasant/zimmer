import XCTest
@testable import ZimmerKit

/// The conversation as the page reads it: cut at code fences for the markdown renderer,
/// filtered by the web UI's levels, and widened by a hundred at a time.
final class TranscriptTests: XCTestCase {
    func testProseIsCutAtCodeFences() {
        let text = "Two ways:\n\n- one\n- two\n\n```sh\nbin/rails db:upgrade\n```\n\nWhich?"
        XCTAssertEqual(MessageSegment.segments(of: text), [
            .prose("Two ways:\n\n- one\n- two"),
            .code("bin/rails db:upgrade", language: "sh"),
            .prose("Which?"),
        ])
    }

    func testAnUnclosedFenceRunsToTheEndAndPlainTextIsOneSegment() {
        XCTAssertEqual(MessageSegment.segments(of: "Look:\n```\nx = 1\ny = 2"), [.prose("Look:"), .code("x = 1\ny = 2", language: nil)])
        XCTAssertEqual(MessageSegment.segments(of: "Just words."), [.prose("Just words.")])
        XCTAssertEqual(MessageSegment.segments(of: ""), [])
        XCTAssertEqual(MessageSegment.segments(of: "```\n```"), [.code("", language: nil)], "an empty block is still a block")
    }

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

    func testTheReadSendsItsLimitAndTheFixtureWindowsLikeTheServer() async throws {
        let transport = ScriptedTransport([{ _ in Fixtures.json(200, ["messages": [], "total": 0, "truncated": false]) }])
        let api = ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport)
        _ = try await api.conversation(7, limit: 200)
        XCTAssertEqual(transport.sent.first?.url.query, "limit=200")

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
