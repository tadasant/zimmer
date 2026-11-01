import XCTest
@testable import ZimmerKit

final class BoardPollingTests: XCTestCase {
    func testThePollerReadsOneAtATimeWhileTheAppIsInFront() {
        var polling = BoardPolling()
        XCTAssertTrue(polling.beginPoll())
        XCTAssertFalse(polling.beginPoll(), "a second poll would ask the same question")
        polling.endPoll()
        XCTAssertTrue(polling.beginPoll())
    }

    func testAnOverdueTickWhileThePhoneIsWakingTheAppIsHeld() {
        // Away longer than the interval: the poller's sleep ends as the process resumes,
        // before the scene is in front and before the network is back.
        var polling = BoardPolling()
        polling.wentToBackground()
        XCTAssertFalse(polling.beginPoll(), "the tick must not take the slot the return to the front needs")
        XCTAssertFalse(polling.pollOut)
        polling.cameToFront()
        XCTAssertTrue(polling.beginPoll())
    }

    func testEachReturnToTheFrontRestartsThePoller() {
        var polling = BoardPolling()
        XCTAssertEqual(polling.returns, 0)
        polling.wentToBackground()
        polling.cameToFront()
        XCTAssertEqual(polling.returns, 1)
        // Control Centre pulled down and put away: in front again without the background.
        polling.cameToFront()
        XCTAssertEqual(polling.returns, 2)
        XCTAssertTrue(polling.inFront)
    }

    func testAReturnToTheFrontDoesNotWaitOnAPollThePhoneSuspended() {
        // The poll went out just before the phone locked; it is still out on return. The read
        // the return makes goes regardless, and the newer ticket is the one that lands.
        var polling = BoardPolling()
        var freshness = BoardFreshness()
        XCTAssertTrue(polling.beginPoll())
        let suspended = freshness.begin()
        polling.wentToBackground()
        polling.cameToFront()
        XCTAssertTrue(polling.pollOut, "still out, and not asked by the return's read")
        let onReturn = freshness.begin()
        XCTAssertTrue(freshness.finish(onReturn))
        XCTAssertFalse(freshness.finish(suspended), "the suspended read's late answer does not replace it")
    }
}
