import XCTest
@testable import ZimmerKit

final class BoardFreshnessTests: XCTestCase {
    func testTheNewestReadReplacesTheList() {
        var freshness = BoardFreshness()
        let ticket = freshness.begin()
        XCTAssertTrue(freshness.finish(ticket))
    }

    func testAnOlderReadThatAnswersLastIsDropped() {
        // A poll is out when a pull starts; the pull answers first, then the poll.
        var freshness = BoardFreshness()
        let poll = freshness.begin()
        let pull = freshness.begin()
        XCTAssertTrue(freshness.finish(pull))
        XCTAssertFalse(freshness.finish(poll), "the older answer would put back what the newer one removed")
    }

    func testAReadOutWhenARowIsTrashedHereIsDropped() {
        // The read was asked before the trash, so its rows still hold the trashed session.
        var freshness = BoardFreshness()
        let poll = freshness.begin()
        freshness.noteLocalChange()
        XCTAssertFalse(freshness.finish(poll))
        // The read after the trash asks the server as it now stands.
        let after = freshness.begin()
        XCTAssertTrue(freshness.finish(after))
    }

    func testTheReadAfterAnActionIsKept() {
        var freshness = BoardFreshness()
        freshness.noteLocalChange()
        let ticket = freshness.begin()
        XCTAssertTrue(freshness.admits(ticket))
    }

    func testComingBackReadsUnlessTheListWasJustRead() {
        var freshness = BoardFreshness()
        let start = Date()
        XCTAssertTrue(freshness.isStale(at: start), "never read")
        XCTAssertTrue(freshness.finish(freshness.begin(), at: start))
        XCTAssertFalse(freshness.isStale(at: start.addingTimeInterval(2)), "read two seconds ago, by the launch")
        XCTAssertTrue(freshness.isStale(at: start.addingTimeInterval(BoardFreshness.staleAfter)))
    }

    func testAFailedReadBringsTheNextOneSooner() {
        var freshness = BoardFreshness()
        XCTAssertEqual(freshness.nextPoll, BoardFreshness.interval)
        freshness.fail(freshness.begin())
        XCTAssertEqual(freshness.nextPoll, BoardFreshness.retryInterval)
        XCTAssertTrue(freshness.finish(freshness.begin()))
        XCTAssertEqual(freshness.nextPoll, BoardFreshness.interval)
    }

    func testOnlyTheNewestReadsFailureCounts() {
        var freshness = BoardFreshness()
        let old = freshness.begin()
        XCTAssertTrue(freshness.finish(freshness.begin()))
        freshness.fail(old)
        XCTAssertEqual(freshness.nextPoll, BoardFreshness.interval)
    }

    func testTheFakeTrashesASessionElsewhereWhenAnotherIsOpened() async throws {
        let fake = FakeZimmerAPI(trashedElsewhere: 1035)
        let before = try await fake.sessions(.default, board: .onBoard, view: .lastTouched).sessions
        XCTAssertTrue(before.contains { $0.id == 1035 })
        _ = try await fake.openSession(1038)
        let after = try await fake.sessions(.default, board: .onBoard, view: .lastTouched).sessions
        XCTAssertFalse(after.contains { $0.id == 1035 }, "the server no longer lists it")
    }
}
