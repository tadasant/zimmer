import XCTest
@testable import ZimmerKit

/// What a New does after a call from standby ended before Zimmer answered it (`LiveNew`). Starting a
/// conversation ends the open one, so the wrong answer here ends the one the driver just asked for.
final class LiveNewTests: XCTestCase {
    func testAFreshNewStarts() {
        XCTAssertEqual(LiveNew().step, .start)
        XCTAssertNil(LiveNew().unanswered)
    }

    func testARetryBeforeTheAnswerAsksForTheSameOne() {
        var new = LiveNew()
        new.began(on: 46)
        XCTAssertEqual(new.step, .askAgain(46), "not whatever is in standby by now, which would end 46 once it lands")
        XCTAssertEqual(new.unanswered, 46)
    }

    func testARetryAfterALateAnswerGoesBackToIt() {
        var new = LiveNew()
        new.began(on: 46)
        new.answered(46, with: 46)
        XCTAssertEqual(new.step, .carryOn(46), "with whatever was said in it")
        XCTAssertNil(new.unanswered)
    }

    func testOneThatWasGoneIsTheOneZimmerGaveInstead() {
        var new = LiveNew()
        new.began(on: 46)
        new.answered(46, with: 51)
        XCTAssertEqual(new.step, .carryOn(51))
    }

    func testAnAnswerToAnOlderNewChangesNothing() {
        var new = LiveNew()
        new.began(on: 46)
        new.began(on: 47)
        new.answered(46, with: 46)
        XCTAssertEqual(new.step, .askAgain(47))
    }

    func testWhichCallsAreThisNewAgain() {
        var new = LiveNew()
        XCTAssertFalse(new.isThis(tap: .startNew, conversation: nil), "there is none to be")
        new.began(on: 46)
        XCTAssertTrue(new.isThis(tap: .startNew, conversation: nil), "the car's retry")
        XCTAssertTrue(new.isThis(tap: nil, conversation: 46), "Talk on its screen, or the gear's call back")
        XCTAssertFalse(new.isThis(tap: .continueOpen, conversation: nil))
        XCTAssertFalse(new.isThis(tap: nil, conversation: 45))
    }
}
