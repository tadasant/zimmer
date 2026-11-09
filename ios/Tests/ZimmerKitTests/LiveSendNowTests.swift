import Foundation
import XCTest
@testable import ZimmerKit

/// Send now: the conductor ending a turn turn detection has not, once, and the races with turn
/// detection ending it too; and the debounce and timings `LiveSendNow` reports.
final class LiveSendNowTests: XCTestCase {
    private func event(_ json: String) -> JSONValue { JSONValue.parse(json)! }

    private func sent(_ effects: [RealtimeConductor.Effect]) -> [JSONValue] {
        effects.compactMap { if case let .send(value) = $0 { return value } else { return nil } }
    }

    private func types(_ effects: [RealtimeConductor.Effect]) -> [String] {
        sent(effects).map { $0["type"]?.string ?? "?" }
    }

    private func ended(_ result: RealtimeConductor.EndTurn, file: StaticString = #filePath, line: UInt = #line) -> [RealtimeConductor.Effect] {
        guard case let .ended(effects) = result else {
            XCTFail("expected the turn to end, got \(result)", file: file, line: line)
            return []
        }
        return effects
    }

    private let speechStarted = #"{"type":"input_audio_buffer.speech_started","audio_start_ms":100}"#
    private let speechStopped = #"{"type":"input_audio_buffer.speech_stopped","audio_end_ms":900}"#
    private let committed = #"{"type":"input_audio_buffer.committed","item_id":"u1"}"#

    // MARK: - The conductor

    func testNothingHeardIsNothingToSend() {
        var conductor = RealtimeConductor()
        XCTAssertFalse(conductor.canEndTurn)
        XCTAssertEqual(conductor.endTurn(), .nothingToSend)
    }

    func testSpeechHeardEndsTheTurnWithACommitAndAsksForTheReply() {
        var conductor = RealtimeConductor()
        _ = conductor.handle(event(speechStarted))
        XCTAssertTrue(conductor.canEndTurn, "speech heard and the turn still open")

        let effects = ended(conductor.endTurn())
        XCTAssertEqual(types(effects), ["input_audio_buffer.commit", "response.create"])
        for value in sent(effects) {
            XCTAssertTrue(value["event_id"]?.string?.hasPrefix(RealtimeConductor.sendNowEventPrefix) == true, "tagged, so a refusal is known for a race")
        }
        XCTAssertTrue(effects.contains(.state(.thinking)), "the screen moves on to Zimmer's turn at once")
        XCTAssertTrue(effects.contains(.signal(.heardPerson)), "the heard cue says it went: nothing to read")
        XCTAssertFalse(conductor.canEndTurn, "Send now goes as soon as it is pressed")
    }

    func testASecondTapSendsNothingWhileTheFirstIsOutOrAfterIt() {
        var conductor = RealtimeConductor()
        _ = conductor.handle(event(speechStarted))
        _ = ended(conductor.endTurn())
        XCTAssertEqual(conductor.endTurn(), .alreadySending, "the commit is still out")
        _ = conductor.handle(event(committed))
        XCTAssertEqual(conductor.endTurn(), .nothingToSend, "committed: the turn is over")
    }

    func testATapAfterTurnDetectionEndedTheTurnSendsNothing() {
        var conductor = RealtimeConductor()
        _ = conductor.handle(event(speechStarted))
        _ = conductor.handle(event(speechStopped))
        XCTAssertFalse(conductor.canEndTurn)
        XCTAssertEqual(conductor.endTurn(), .nothingToSend, "no empty commit, no second reply")
    }

    /// The race the other way: the tap went first, and turn detection's own end of the same turn
    /// arrives after it. It is not a second end: no cue again, no second Working.
    func testTurnDetectionsLateEndOfATurnSendNowEndedSaysNothing() {
        var conductor = RealtimeConductor()
        _ = conductor.handle(event(speechStarted))
        _ = ended(conductor.endTurn())
        XCTAssertEqual(conductor.handle(event(speechStopped)), [])
        // The next turn is a turn like any other.
        _ = conductor.handle(event(committed))
        _ = conductor.handle(event(#"{"type":"response.created"}"#))
        _ = conductor.handle(event(#"{"type":"response.done","response":{"status":"completed","output":[]}}"#))
        _ = conductor.handle(event(speechStarted))
        XCTAssertTrue(conductor.handle(event(speechStopped)).contains(.signal(.heardPerson)))
    }

    /// OpenAI refuses what Send now sent because turn detection beat it there: the commit found
    /// an empty buffer, or the reply was already running. That is the race, not a failure.
    func testARefusalOfWhatSendNowSentIsNotAFailure() {
        var conductor = RealtimeConductor()
        _ = conductor.handle(event(speechStarted))
        let effects = ended(conductor.endTurn())
        let commitID = sent(effects)[0]["event_id"]!.string!
        let responseID = sent(effects)[1]["event_id"]!.string!
        // Turn detection's own reply is running.
        _ = conductor.handle(event(#"{"type":"response.created"}"#))
        let emptyCommit = conductor.handle(event(#"{"type":"error","error":{"code":"input_audio_buffer_commit_empty","event_id":"\#(commitID)"}}"#))
        XCTAssertFalse(emptyCommit.contains { if case .failure = $0 { return true } else { return false } }, "\(emptyCommit)")
        let busy = conductor.handle(event(#"{"type":"error","error":{"code":"conversation_already_has_active_response","event_id":"\#(responseID)"}}"#))
        XCTAssertEqual(busy, [], "a reply is running: nothing to say and nothing to change")
        // Anybody else's error is still a failure.
        let other = conductor.handle(event(#"{"type":"error","error":{"message":"boom"}}"#))
        XCTAssertTrue(other.contains(.failure("boom")))
    }

    func testARefusalWithNothingComingIsBackToListening() {
        var conductor = RealtimeConductor()
        _ = conductor.handle(event(speechStarted))
        let effects = ended(conductor.endTurn())
        let responseID = sent(effects)[1]["event_id"]!.string!
        let refused = conductor.handle(event(#"{"type":"error","error":{"event_id":"\#(responseID)"}}"#))
        XCTAssertEqual(refused, [.signal(.noAnswerComing), .state(.listening)], "not stuck on Working")
    }

    /// The driver talked over a reply and pressed Send now before OpenAI finished cancelling it:
    /// the reply is asked for once that response is done, and only once.
    func testSendNowDuringABargeInAsksForTheReplyAfterTheCancelledOne() {
        var conductor = RealtimeConductor()
        _ = conductor.handle(event(#"{"type":"response.created"}"#))
        _ = conductor.handle(event(#"{"type":"response.output_audio.delta","item_id":"r1","delta":"AAAA"}"#))
        let barge = conductor.handle(event(speechStarted))
        XCTAssertTrue(barge.contains(.interrupt(arriving: "r1")))
        XCTAssertTrue(conductor.canEndTurn)

        let effects = ended(conductor.endTurn())
        XCTAssertEqual(types(effects), ["input_audio_buffer.commit"], "not on top of the response being cancelled")
        let done = conductor.handle(event(#"{"type":"response.done","response":{"status":"cancelled","output":[]}}"#))
        XCTAssertEqual(types(done), ["response.create"])
        let next = conductor.handle(event(#"{"type":"response.created"}"#)) + conductor.handle(event(#"{"type":"response.done","response":{"status":"completed","output":[]}}"#))
        XCTAssertFalse(types(next).contains("response.create"), "one reply, not two")
    }

    /// Gated (wake word, dynamic), Zimmer says whether a line gets a reply: Send now ends the turn
    /// and leaves that to it.
    func testGatedSendNowCommitsAndLeavesTheReplyToZimmer() {
        var conductor = RealtimeConductor(listening: "wake_word")
        _ = conductor.handle(event(speechStarted))
        let effects = ended(conductor.endTurn())
        XCTAssertEqual(types(effects), ["input_audio_buffer.commit"])
        XCTAssertFalse(effects.contains(.signal(.heardPerson)), "heard once Zimmer says it gets an answer")
    }

    func testANewTurnCanBeSentAgain() {
        var conductor = RealtimeConductor()
        _ = conductor.handle(event(speechStarted))
        _ = ended(conductor.endTurn())
        _ = conductor.handle(event(committed))
        _ = conductor.handle(event(speechStarted))
        XCTAssertTrue(conductor.canEndTurn)
        let again = ended(conductor.endTurn())
        XCTAssertNotEqual(sent(again)[0]["event_id"], nil)
        XCTAssertEqual(sent(again)[0]["event_id"]?.string, "\(RealtimeConductor.sendNowEventPrefix)2_commit", "each send is its own")
    }

    // MARK: - The log

    private func fields(_ event: LiveEvent) -> [String: JSONValue] { event.fields() }

    private func pcm(level: Int16, samples: Int = 2_400) -> Data {
        var data = Data()
        for index in 0..<samples {
            let value = index.isMultiple(of: 2) ? level : -level
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    func testTapsInsideTheDebounceAreOneTap() {
        var log = LiveSendNow()
        XCTAssertTrue(log.tap(at: 10))
        XCTAssertFalse(log.tap(at: 10.3), "a bounce")
        XCTAssertFalse(log.tap(at: 10.79))
        XCTAssertTrue(log.tap(at: 10 + LiveSendNow.debounce), "counted from the tap that counted")
    }

    func testATapIsLoggedWithItsOutcomeAndTimingsAndNoWords() {
        var log = LiveSendNow()
        _ = log.observe(event(#"{"type":"session.created","session":{"audio":{"input":{"turn_detection":{"type":"server_vad","silence_duration_ms":800}}}}}"#), at: 0)
        _ = log.observe(event(speechStarted), at: 1)
        log.heard(pcm16: pcm(level: 8_000), at: 2)
        log.heard(pcm16: pcm(level: 50), at: 2.1)
        let tapped = log.record(.submitted, surface: "carplay", at: 2.3)
        XCTAssertEqual(tapped.name, "turn.send_now")
        let values = fields(tapped)
        XCTAssertEqual(values["outcome"], .string("submitted"))
        XCTAssertEqual(values["surface"], .string("carplay"))
        XCTAssertEqual(values["turn_detection"], .string("server_vad"))
        XCTAssertEqual(values["since_speech_started_ms"], .number(1_300))
        XCTAssertEqual(values["since_last_voice_ms"], .number(300), "the quiet frame is not a voice")
        XCTAssertEqual(values["since_turn_ended_ms"], .null)
        for value in values.values {
            if case let .string(text) = value { XCTAssertLessThan(text.count, 24, "names and settings only") }
        }
    }

    /// Under Silence the pause still to run is known at the tap; and turn detection's own end of
    /// the turn, arriving soon after, is the signal it would have fired anyway.
    func testTheFollowupSaysWhetherTurnDetectionWouldHaveFiredSoon() {
        var log = LiveSendNow()
        _ = log.observe(event(#"{"type":"session.created","session":{"audio":{"input":{"turn_detection":{"type":"server_vad","silence_duration_ms":800}}}}}"#), at: 0)
        _ = log.observe(event(speechStarted), at: 1)
        log.heard(pcm16: pcm(level: 8_000), at: 2)
        _ = log.record(.submitted, surface: "carplay", at: 2.5)
        let followup = log.observe(event(speechStopped), at: 2.9)
        XCTAssertEqual(followup.map(\.name), ["turn.send_now_followup"])
        let values = fields(followup[0])
        XCTAssertEqual(values["vad_turn_end_after_ms"], .number(400))
        XCTAssertEqual(values["estimated_auto_after_ms"], .number(300), "800 ms of pause, 500 already gone")
        XCTAssertEqual(values["auto_soon"], .bool(true))
        XCTAssertTrue(log.expire(at: 100).isEmpty, "one follow-up per send")
    }

    func testAFollowupWithNoWordFromTurnDetectionUnderSemanticIsNotSoon() {
        var log = LiveSendNow()
        _ = log.observe(event(#"{"type":"session.created","session":{"audio":{"input":{"turn_detection":{"type":"semantic_vad","eagerness":"low"}}}}}"#), at: 0)
        _ = log.observe(event(speechStarted), at: 1)
        let tapped = fields(log.record(.submitted, surface: "carplay", at: 4))
        XCTAssertEqual(tapped["eagerness"], .string("low"))
        XCTAssertTrue(log.expire(at: 6).isEmpty, "the window is still open")
        let followup = log.expire(at: 4 + LiveSendNow.followWindow)
        XCTAssertEqual(followup.map(\.name), ["turn.send_now_followup"])
        XCTAssertEqual(fields(followup[0])["vad_turn_end_after_ms"], .null)
        XCTAssertEqual(fields(followup[0])["estimated_auto_after_ms"], .null, "Semantic's wait is the model's")
        XCTAssertEqual(fields(followup[0])["auto_soon"], .bool(false))
    }

    func testATapThatFoundTheTurnEndedSaysHowRecently() {
        var log = LiveSendNow()
        _ = log.observe(event(speechStarted), at: 1)
        _ = log.observe(event(speechStopped), at: 3)
        let values = fields(log.record(.ignoredEmpty, surface: "carplay", at: 3.2))
        XCTAssertEqual(values["outcome"], .string("ignored_empty"))
        XCTAssertEqual(values["since_turn_ended_ms"], .number(200), "the driver was reaching for it as the call moved on")
        XCTAssertTrue(log.expire(at: 100).isEmpty, "nothing sent, nothing to follow up")
    }

    func testEveryOutcomeHasItsName() {
        XCTAssertEqual(LiveSendNow.Outcome.allCases.map(\.rawValue), ["submitted", "ignored_empty", "ignored_in_flight", "ignored_debounced"])
    }
}
