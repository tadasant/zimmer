import XCTest
@testable import ZimmerKit

/// The car's call screen: its five states, Send now's place among them, and the conductor's
/// opening line.
final class LiveCallScreenTests: XCTestCase {
    func testALostMicrophoneReadsAsConnectingWhateverTheCallIsDoing() {
        for state in [LiveVoiceState.listening, .speaking, .working] {
            XCTAssertEqual(LiveCallScreen.identifier(for: state, muted: false, microphoneLost: true), "connecting")
            XCTAssertEqual(LiveCallScreen.identifier(for: state, muted: true, microphoneLost: true), "connecting", "Muted would say the driver chose this")
        }
        XCTAssertEqual(LiveCallScreen.identifier(for: .listening, muted: false, microphoneLost: false), "listening")
    }

    /// The regression test for the call screen CarPlay could not show: ten states, a muted twin
    /// of each, of which CarPlay keeps five — so *speaking* and *working* were never there to
    /// activate.
    func testTheCallScreenFitsTheFiveStatesCarPlayKeepsAndNamesOneForEveryCallState() {
        XCTAssertEqual(LiveCallScreen.identifiers.count, LiveCallScreen.maximumStates)
        XCTAssertEqual(Set(LiveCallScreen.identifiers).count, LiveCallScreen.identifiers.count, "no two states share an identifier")
        let built = Set(LiveCallScreen.identifiers)
        for state in [LiveVoiceState.idle, .connecting, .listening, .thinking, .speaking, .working] {
            for muted in [false, true] {
                XCTAssertTrue(built.contains(LiveCallScreen.identifier(for: state, muted: muted)), "\(state), muted \(muted), activates a state the screen has")
            }
        }
        XCTAssertEqual(LiveCallScreen.identifiers.first, "connecting", "the screen opens on connecting")
    }

    func testMutedShowsWhateverTheCallIsDoingAndEachStateHasItsWord() {
        for state in [LiveVoiceState.connecting, .listening, .thinking, .speaking, .working] {
            XCTAssertEqual(LiveCallScreen.identifier(for: state, muted: true), "muted")
        }
        for state in [LiveVoiceState.thinking, .working, .speaking] {
            XCTAssertEqual(LiveCallScreen.identifier(for: state, muted: false), "replying", "\(state) is Zimmer's turn, to a driver")
        }
        XCTAssertEqual(LiveCallScreen.identifier(for: .idle, muted: false), "connecting")
        XCTAssertEqual(LiveCallScreen.identifiers.map(LiveCallScreen.title(for:)), ["Connecting…", "Listening", "Hearing you", "Replying", "Muted"])
    }

    /// Send now is on the screen only while the driver is heard and turn detection has not ended
    /// the turn: never during a reply, never muted, never with the microphone lost, never with
    /// nothing heard.
    func testSendNowIsOfferedOnlyWhileThereIsSpeechToSend() {
        XCTAssertTrue(LiveCallScreen.identifiers.contains(LiveCallScreen.sendNowState))
        XCTAssertEqual(LiveCallScreen.identifier(for: .listening, muted: false, speechHeard: true), "hearing")
        XCTAssertTrue(LiveCallScreen.offersSendNow(for: .listening, muted: false, microphoneLost: false, speechHeard: true))
        XCTAssertFalse(LiveCallScreen.offersSendNow(for: .listening, muted: false, microphoneLost: false, speechHeard: false), "nothing heard: nothing to send")
        for state in [LiveVoiceState.idle, .connecting, .thinking, .speaking, .working] {
            XCTAssertFalse(LiveCallScreen.offersSendNow(for: state, muted: false, microphoneLost: false, speechHeard: true), "\(state): not while Zimmer has the turn")
        }
        XCTAssertFalse(LiveCallScreen.offersSendNow(for: .listening, muted: true, microphoneLost: false, speechHeard: true), "muted")
        XCTAssertFalse(LiveCallScreen.offersSendNow(for: .listening, muted: false, microphoneLost: true, speechHeard: true), "microphone lost")
        XCTAssertEqual(LiveCallScreen.title(for: LiveCallScreen.sendNowState), "Hearing you")
        XCTAssertLessThanOrEqual(LiveCallScreen.sendNowTitle.count, 10, "two short words a driver takes in at a glance")
        XCTAssertEqual(LiveCallScreen.sendNowSymbol, "paperplane.fill", "the symbol is what CarPlay draws and what VoiceOver reads")
    }

    func testTheConductorOpensACallWithALineAndAsksForTheReply() {
        var conductor = RealtimeConductor()
        let effects = conductor.open(with: "Let's talk about session 3.")
        XCTAssertEqual(effects.count, 2)
        guard case let .send(item) = effects[0], case let .send(create) = effects[1] else { return XCTFail("\(effects)") }
        XCTAssertEqual(item["type"]?.string, "conversation.item.create")
        XCTAssertEqual(item["item"]?["role"]?.string, "user")
        XCTAssertEqual(item["item"]?["content"]?.array?.first?["text"]?.string, "Let's talk about session 3.")
        XCTAssertEqual(create["type"]?.string, "response.create")

        // Not on top of a reply already running: the ask waits for that response to finish.
        var busy = RealtimeConductor()
        _ = busy.handle(.object(["type": .string("response.created")]))
        let queued = busy.open(with: "Hi")
        XCTAssertEqual(queued.count, 1, "only the item; the response.create comes after response.done")
        let after = busy.handle(.object(["type": .string("response.done"), "response": .object(["status": .string("completed"), "output": .array([])])]))
        XCTAssertTrue(after.contains { if case let .send(event) = $0 { return event["type"]?.string == "response.create" } else { return false } })
    }
}
