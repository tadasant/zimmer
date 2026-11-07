import XCTest
@testable import ZimmerKit

/// When the phone goes to a call the car left on it. The screens are `LiveHandoverUITests`', and
/// the Simulator's true disconnect is the CarPlay drill's; every order of events is here.
final class LiveHandoverTests: XCTestCase {
    private let settled = LiveHandover.settle

    private func armed(conversation: Int = 21, at: TimeInterval = 100) -> LiveHandover {
        var handover = LiveHandover()
        handover.carLeft(conversation: conversation, callIsActive: true, at: at)
        return handover
    }

    private func step(_ handover: inout LiveHandover, call: Int? = 21, active: Bool = true, inFront: Bool = true,
                      screen: LiveHandover.Screen = .free, after: TimeInterval) -> LiveHandover.Step {
        handover.step(callConversation: call, callIsActive: active, inFront: inFront, screen: screen, at: 100 + after)
    }

    // MARK: - What arms it

    func testACallUpWhenTheCarGoesLandsOnItsThread() {
        var handover = armed()
        XCTAssertEqual(step(&handover, after: settled), .land(21))
    }

    func testACallThatMovesConversationAfterTheCarWentLandsWhereTheCallIsNow() {
        var handover = armed()
        handover.callMoved(to: 30)
        XCTAssertEqual(step(&handover, call: 30, after: settled - 1), .wait, "the settle still counts from when the car left")
        XCTAssertEqual(step(&handover, call: 30, after: settled), .land(30))
    }

    func testACallMovingWithNoRouteArmsNothing() {
        var handover = LiveHandover()
        handover.callMoved(to: 30)
        XCTAssertNil(handover.route)
    }

    func testNoCallWhenTheCarGoesArmsNothing_aRetryOrACallTheGearOrTheDriverEnded() {
        var handover = LiveHandover()
        // The gear's hang-up, a failed call waiting on its retry and an End all leave `conversationID`
        // set on an idle call.
        handover.carLeft(conversation: 21, callIsActive: false, at: 100)
        XCTAssertNil(handover.route)
        XCTAssertEqual(step(&handover, after: settled), .nothing)
    }

    func testACallWithNoConversationArmsNothing() {
        var handover = LiveHandover()
        handover.carLeft(conversation: nil, callIsActive: true, at: 100)
        XCTAssertNil(handover.route)
    }

    func testAnIdleDisconnectForgetsAnOlderRoute() {
        var handover = armed()
        handover.carLeft(conversation: 21, callIsActive: false, at: 110)
        XCTAssertNil(handover.route)
    }

    // MARK: - The settle, and the flap

    func testNothingMovesUntilTheCarHasStayedGone() {
        var handover = armed()
        XCTAssertEqual(step(&handover, after: settled - 0.1), .wait)
        XCTAssertEqual(step(&handover, after: settled), .land(21))
    }

    func testACarThatCameBackInsideTheSettleLeavesThePhoneAlone() {
        var handover = armed()
        handover.carCameBack()
        XCTAssertNil(handover.route, "no stale route left armed")
        XCTAssertEqual(step(&handover, after: 60), .nothing)
    }

    func testDisconnectReconnectDisconnectSettlesFromTheLastDisconnect() {
        var handover = armed(at: 100)
        handover.carCameBack()
        handover.carLeft(conversation: 21, callIsActive: true, at: 102)
        XCTAssertEqual(step(&handover, after: settled), .wait, "the first disconnect's clock is gone with it")
        XCTAssertEqual(step(&handover, after: 2 + settled), .land(21))
        XCTAssertEqual(step(&handover, after: 2 + settled), .nothing, "once")
    }

    func testACarRestartWithoutADisconnectLeavesNothingArmed() {
        // `didConnect` tears the old scene down, which arms, and then says the car is back.
        var handover = LiveHandover()
        handover.carLeft(conversation: 21, callIsActive: true, at: 100)
        handover.carCameBack()
        XCTAssertNil(handover.route)
    }

    func testACarThatComesBackAfterTheLandingFindsNothingArmed() {
        var handover = armed()
        XCTAssertEqual(step(&handover, after: settled), .land(21))
        handover.carCameBack()
        XCTAssertNil(handover.route)
    }

    // MARK: - The next foreground

    func testInTheBackgroundItWaitsWithoutALimit() {
        var handover = armed()
        XCTAssertEqual(step(&handover, inFront: false, after: settled), .wait)
        XCTAssertEqual(step(&handover, inFront: false, after: 3_600), .wait)
        XCTAssertEqual(step(&handover, inFront: true, after: 3_600), .land(21), "the call is still up: it is what the phone is doing")
    }

    func testAForegroundInsideTheSettleWaitsItOut() {
        var handover = armed()
        XCTAssertEqual(step(&handover, inFront: true, after: 1), .wait)
        XCTAssertEqual(step(&handover, inFront: true, after: settled), .land(21))
    }

    func testACallThatEndedInThePocketIsForgotten() {
        var handover = armed()
        handover.callEnded()
        XCTAssertEqual(step(&handover, active: false, inFront: true, after: 600), .nothing)
    }

    func testOnArrivalADeadCallIsCheckedEvenIfNothingForgotTheRoute() {
        var handover = armed()
        XCTAssertEqual(step(&handover, active: false, after: settled), .nothing)
        XCTAssertNil(handover.route)
    }

    func testOnArrivalACallOnAnotherConversationIsNotThisRoute() {
        var handover = armed()
        XCTAssertEqual(step(&handover, call: 34, after: settled), .nothing)
        XCTAssertNil(handover.route)
    }

    func testThePersonOpeningSomethingOnPurposeWins() {
        var handover = armed()
        handover.personChoseElsewhere()
        XCTAssertEqual(step(&handover, after: settled), .nothing)
    }

    // MARK: - What is on screen

    func testAnythingOverTheTabsHoldsItUntilItCloses() {
        var handover = armed()
        XCTAssertEqual(step(&handover, screen: .busy, after: settled), .wait)
        XCTAssertEqual(step(&handover, screen: .busy, after: 600), .wait, "for as long as it stays up")
        XCTAssertEqual(step(&handover, screen: .free, after: 601), .land(21))
    }

    func testACallThatEndsBehindASheetLandsNowhere() {
        var handover = armed()
        XCTAssertEqual(step(&handover, screen: .busy, after: settled), .wait)
        handover.callEnded()
        XCTAssertEqual(step(&handover, active: false, screen: .free, after: 60), .nothing)
    }

    func testLivesOwnListGoesToTheThread() {
        var handover = armed()
        XCTAssertEqual(step(&handover, screen: .liveList, after: settled), .land(21))
    }

    func testAlreadyOnTheCallsThreadSpendsTheRouteWithNoMove() {
        var handover = armed()
        XCTAssertEqual(step(&handover, screen: .liveThread(21), after: settled), .nothing)
        XCTAssertNil(handover.route)
    }

    func testAnotherThreadIsLeftAloneUntilThePersonLeavesIt() {
        var handover = armed()
        XCTAssertEqual(step(&handover, screen: .liveThread(9), after: settled), .wait, "it may hold a draft")
        XCTAssertEqual(step(&handover, screen: .liveList, after: settled + 5), .land(21))
    }
}
