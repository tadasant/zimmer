import XCTest
@testable import ZimmerKit

/// A message shows under the conversation from the moment it is sent, and comes down again
/// only once the server shows it itself — or when a person decides about one that failed.
final class OutgoingMessagesTests: XCTestCase {
    private let sentAt = Date(timeIntervalSince1970: 1_700_000_000)

    private func conversation(_ messages: [(ConversationMessage.Role, String)]) -> Conversation {
        Conversation(messages: messages.enumerated().map { index, pair in
            ConversationMessage(id: index, role: pair.0, content: pair.1)
        })
    }

    func testASentMessageStaysWhileTheServerHasNotAnswered() {
        var outgoing = OutgoingMessages()
        outgoing.add(OutgoingMessage(content: "Merge it.", sentAt: sentAt, conversationTotal: 2))
        outgoing.reconcile(conversation: conversation([(.assistant, "Ready?"), (.user, "Merge it.")]), queue: [], now: sentAt)
        XCTAssertEqual(outgoing.messages.count, 1, "an earlier message with the same words is not this one")
        XCTAssertTrue(outgoing.hasSending)
    }

    func testADeliveredMessageComesDownOnceTheTranscriptShowsIt() {
        var outgoing = OutgoingMessages()
        let id = outgoing.add(OutgoingMessage(content: "Merge it.", sentAt: sentAt, conversationTotal: 2))
        outgoing.delivered(id, queued: false)
        XCTAssertEqual(outgoing.messages.first?.state, .delivered)
        outgoing.reconcile(conversation: conversation([(.assistant, "Ready?"), (.user, "Merge it.")]), queue: [], now: sentAt)
        XCTAssertEqual(outgoing.messages.count, 1, "the transcript has only the older message with these words")
        outgoing.reconcile(conversation: conversation([(.assistant, "Ready?"), (.user, "Merge it."), (.user, "Merge it.")]), queue: [], now: sentAt)
        XCTAssertTrue(outgoing.isEmpty, "the message at a position past where the conversation stood is this one")
    }

    func testTheTranscriptMayWrapTheWords() {
        var outgoing = OutgoingMessages()
        let id = outgoing.add(OutgoingMessage(content: "Look at this", attachmentCount: 1, sentAt: sentAt, conversationTotal: 0))
        outgoing.delivered(id, queued: false)
        outgoing.reconcile(conversation: conversation([(.user, "Look at this\n\n[Attached: photo.jpg]")]), queue: [], now: sentAt)
        XCTAssertTrue(outgoing.isEmpty)
    }

    func testAQueuedMessageComesDownOnceTheQueueShowsIt() {
        var outgoing = OutgoingMessages()
        let id = outgoing.add(OutgoingMessage(content: "Then run the tests.", sentAt: sentAt, conversationTotal: 4))
        outgoing.delivered(id, queued: true)
        outgoing.reconcile(conversation: nil, queue: [], now: sentAt)
        XCTAssertEqual(outgoing.messages.first?.state, .queued)
        outgoing.reconcile(conversation: nil, queue: [QueuedMessage(id: 7, content: "Then run the tests.", position: 1)], now: sentAt)
        XCTAssertTrue(outgoing.isEmpty)
    }

    func testADeliveredMessageTheTranscriptNeverShowsSettlesOnItsOwn() {
        var outgoing = OutgoingMessages()
        let id = outgoing.add(OutgoingMessage(content: "Hello?", sentAt: sentAt, conversationTotal: 0))
        outgoing.delivered(id, queued: false)
        outgoing.reconcile(conversation: conversation([]), queue: [], now: sentAt.addingTimeInterval(OutgoingMessages.settleAfter - 1))
        XCTAssertEqual(outgoing.messages.count, 1)
        outgoing.reconcile(conversation: conversation([]), queue: [], now: sentAt.addingTimeInterval(OutgoingMessages.settleAfter))
        XCTAssertTrue(outgoing.isEmpty)
    }

    func testAFailedMessageStaysWithItsReasonUntilTaken() {
        var outgoing = OutgoingMessages()
        let id = outgoing.add(OutgoingMessage(content: "Merge it.", sentAt: sentAt, conversationTotal: 0))
        outgoing.failed(id, "The server could not be reached.")
        outgoing.reconcile(conversation: conversation([(.user, "Merge it.")]), queue: [], now: .distantFuture)
        XCTAssertEqual(outgoing.messages.count, 1, "neither the transcript nor time takes a failure down")
        XCTAssertTrue(outgoing.messages[0].isFailed)
        XCTAssertEqual(outgoing.messages[0].failure, "The server could not be reached.")
        XCTAssertFalse(outgoing.hasSending)
        let taken = outgoing.take(id)
        XCTAssertEqual(taken?.content, "Merge it.", "the words come back for the composer or another try")
        XCTAssertTrue(outgoing.isEmpty)
        XCTAssertNil(outgoing.take(id), "taken once")
    }

    func testAnAnswerForAnUnknownMessageIsIgnored() {
        var outgoing = OutgoingMessages()
        outgoing.delivered(UUID(), queued: false)
        outgoing.failed(UUID(), "lost")
        XCTAssertTrue(outgoing.isEmpty)
    }
}
