import XCTest
@testable import ZimmerKit

/// The car's call screen: its five states, and the conductor's opening line.
final class LiveCallScreenTests: XCTestCase {
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
        XCTAssertEqual(LiveCallScreen.identifier(for: .thinking, muted: false), "working", "thinking is working, to a driver")
        XCTAssertEqual(LiveCallScreen.identifier(for: .idle, muted: false), "connecting")
        XCTAssertEqual(LiveCallScreen.identifiers.map(LiveCallScreen.title(for:)), ["Connecting…", "Listening", "Speaking", "Working on it…", "Muted"])
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
