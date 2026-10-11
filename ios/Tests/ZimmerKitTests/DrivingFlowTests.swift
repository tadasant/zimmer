import XCTest
@testable import ZimmerKit

final class DrivingFlowTests: XCTestCase {
    private let sessions = [
        SessionSummary(id: 1, title: "Running thing", status: .running),
        SessionSummary(id: 2, title: "Merge PR 1261?", status: .needsInput),
        SessionSummary(id: 3, title: "Which Postgres?", status: .needsInput),
    ]

    func testCommandsAreShortAndForgivingAndEverythingElseIsAReply() {
        XCTAssertEqual(VoiceCommand("Yes."), .approve)
        XCTAssertEqual(VoiceCommand("go ahead"), .approve)
        XCTAssertEqual(VoiceCommand("Archive it"), .archive)
        XCTAssertEqual(VoiceCommand("skip"), .next)
        XCTAssertEqual(VoiceCommand("say again"), .repeatCurrent)
        XCTAssertEqual(VoiceCommand("That's all"), .stop)
        XCTAssertEqual(VoiceCommand("Reply use Postgres 16"), .reply("use Postgres 16"))
        XCTAssertEqual(VoiceCommand("use Postgres 16 for now"), .reply("use Postgres 16 for now"))
        XCTAssertNil(VoiceCommand("   "))
        XCTAssertEqual(VoiceCommand("Yes, go ahead."), .approve, "punctuation inside the phrase is not a reply")
        XCTAssertEqual(VoiceCommand("Reply"), .startReply)
    }

    func testABareReplyAsksWhatToSayThenConfirms() {
        var flow = DrivingFlow(sessions: sessions)
        XCTAssertEqual(flow.handle(.startReply), [.speak("What should I tell it?")])
        XCTAssertEqual(flow.handle(.reply("use 16")).count, 1)
        XCTAssertEqual(flow.pending, .confirmReply("use 16"))
        XCTAssertEqual(flow.handle(.approve).first, .followUp(sessionID: 2, text: "use 16"))
    }

    func testStopEndsTheConversationEvenMidConfirmation() {
        var flow = DrivingFlow(sessions: sessions)
        _ = flow.handle(.archive)
        XCTAssertEqual(flow.handle(.stop).last, .end)
        XCTAssertEqual(flow.pending, .none)
    }

    func testTheOpeningCountsOnlyWhatNeedsTheDriverAndReadsTheFirst() {
        let flow = DrivingFlow(sessions: sessions, summaries: [2: "CI is green."])
        XCTAssertEqual(flow.queue.map(\.id), [2, 3])
        guard case let .speak(line)? = flow.opening().first else { return XCTFail("expected speech") }
        XCTAssertTrue(line.hasPrefix("2 sessions need you. Merge PR 1261?. CI is green."))
    }

    func testNothingToDoEndsAtOnce() {
        XCTAssertEqual(DrivingFlow(sessions: [sessions[0]]).opening(), [.speak("Nothing needs you right now."), .end])
    }

    func testApprovingSendsTheCannedReplyAndMovesOn() {
        var flow = DrivingFlow(sessions: sessions)
        let effects = flow.handle(.approve)
        XCTAssertEqual(effects.first, .followUp(sessionID: 2, text: "Yes, go ahead."))
        XCTAssertEqual(flow.current?.id, 3)
    }

    func testArchivingAndReplyingAreConfirmedBeforeAnythingHappens() {
        var flow = DrivingFlow(sessions: sessions)

        XCTAssertFalse(flow.handle(.archive).contains(.archive(sessionID: 2)), "nothing archived on the first word")
        XCTAssertEqual(flow.pending, .confirmArchive)
        XCTAssertEqual(flow.handle(.approve).first, .archive(sessionID: 2))
        XCTAssertEqual(flow.current?.id, 3)

        XCTAssertFalse(flow.handle(.reply("use 16")).contains(.followUp(sessionID: 3, text: "use 16")))
        XCTAssertEqual(flow.handle(.approve).first, .followUp(sessionID: 3, text: "use 16"))
        XCTAssertEqual(flow.current, nil)
    }

    func testAnythingButYesCancelsAPendingAction() {
        var flow = DrivingFlow(sessions: sessions)
        _ = flow.handle(.archive)
        let effects = flow.handle(.next)
        XCTAssertFalse(effects.contains(.archive(sessionID: 2)))
        XCTAssertEqual(flow.pending, .none)
        XCTAssertEqual(flow.current?.id, 2, "a cancelled confirmation stays on the same session")
    }

    func testRunningOffTheEndOrStoppingEndsTheConversation() {
        var flow = DrivingFlow(sessions: sessions)
        _ = flow.handle(.next)
        XCTAssertEqual(flow.handle(.next).last, .end)
        var stopping = DrivingFlow(sessions: sessions)
        XCTAssertEqual(stopping.handle(.stop).last, .end)
    }

    func testTheQueueIsCappedForTheCar() {
        let many = (1...9).map { SessionSummary(id: $0, status: .needsInput) }
        XCTAssertEqual(DrivingFlow(sessions: many).queue.count, DrivingFlow.limit)
    }
}
