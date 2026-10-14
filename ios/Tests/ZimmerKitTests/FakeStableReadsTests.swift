import XCTest
@testable import ZimmerKit

/// The fake answers a second read as the server does: the same, unless something changed. The
/// session page polls, and a read that always differed would redraw the page every few seconds,
/// rebuilding an open menu under a finger.
final class FakeStableReadsTests: XCTestCase {
    func testASessionReadTwiceIsTheSameSession() async throws {
        let fake = FakeZimmerAPI()
        for session in FakeZimmerAPI.sampleSessions() {
            let first = try await fake.session(session.id)
            let second = try await fake.session(session.id)
            XCTAssertEqual(first, second, "session \(session.id) changed between two reads")
        }
    }

    func testEverythingThePagePollsReadsTheSameTwice() async throws {
        let fake = FakeZimmerAPI()
        for session in FakeZimmerAPI.sampleSessions() {
            let conversation = try await fake.conversation(session.id, limit: 100)
            let queue = try await fake.queue(session.id)
            let conversationAgain = try await fake.conversation(session.id, limit: 100)
            let queueAgain = try await fake.queue(session.id)
            XCTAssertEqual(conversation, conversationAgain, "session \(session.id)'s conversation changed between two reads")
            XCTAssertEqual(queue, queueAgain, "session \(session.id)'s queue changed between two reads")
        }
    }
}
