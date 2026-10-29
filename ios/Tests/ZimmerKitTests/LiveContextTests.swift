import XCTest
@testable import ZimmerKit

/// The one line the car's call screen has, and the words for what the call is doing.
final class LiveContextTests: XCTestCase {
    func testActivityNamesWhatTheCallIsDoingNotTheFunction() {
        XCTAssertEqual(LiveActivity.describe(name: "zimmer", arguments: #"{"tool":"quick_router","arguments":{"prompt":"x"}}"#), "Starting work…")
        XCTAssertEqual(LiveActivity.describe(name: "zimmer", arguments: #"{"tool":"get_session","arguments":{"id":1}}"#), "Checking on a session…")
        XCTAssertEqual(LiveActivity.describe(name: "zimmer", arguments: #"{"tool":"quick_search_sessions"}"#), "Looking through sessions…")
        XCTAssertEqual(LiveActivity.describe(name: "zimmer", arguments: #"{"tool":"action_session"}"#), "Following up…")
        XCTAssertEqual(LiveActivity.describe(name: "zimmer", arguments: #"{"tool":"send_push_notification"}"#), "Sending it to your phone…")
        XCTAssertEqual(LiveActivity.describe(name: "zimmer", arguments: #"{"tool":"get_work_backlog"}"#), "Zimmer: get work backlog…")
        XCTAssertEqual(LiveActivity.describe(name: "zimmer", arguments: "not json"), "Asking Zimmer…")
        XCTAssertEqual(LiveActivity.describe(name: "enable_mcp_server", arguments: "{}"), "Changing its tools…")
        XCTAssertEqual(LiveActivity.describe(name: "update_live_settings", arguments: "{}"), "Changing its settings…")
        XCTAssertEqual(LiveActivity.describe(name: "google-calendar__list_events", arguments: "{}"), "Using google calendar…")
        XCTAssertEqual(LiveActivity.describe(name: "something", arguments: "{}"), "Working on it…")
    }

    func testTheTitleIsTheStateThenTheSubjectAndTheShortVariantIsAlwaysTheState() {
        let subject = SessionSummary(id: 1101, title: "Investigate the flaky transcript poller test", status: .running)
        let context = LiveContext(sessions: [subject], activity: "Checking on a session…", needsYou: 2)
        XCTAssertEqual(context.titleVariants(for: .listening), ["Listening · Investigate the flaky transcript poller test: running", "Listening"])
        XCTAssertEqual(context.titleVariants(for: .working), ["Working on it… · Investigate the flaky transcript poller test: running", "Working on it…"],
                       "the activity is not in the title: it changes with every call, and a title is fixed when the template is built")
        var muted = context
        muted.muted = true
        XCTAssertEqual(muted.titleVariants(for: .speaking), ["Speaking · Muted · Investigate the flaky transcript poller test: running", "Speaking · Muted"])

        let nothing = LiveContext()
        XCTAssertEqual(nothing.titleVariants(for: .connecting), ["Connecting…"])
        let waiting = LiveContext(needsYou: 3)
        XCTAssertEqual(waiting.titleVariants(for: .listening), ["Listening · 3 need you", "Listening"])
        XCTAssertEqual(LiveContext(activity: "Starting work…").titleVariants(for: .working), ["Working on it…"])
    }

    func testALongSubjectIsCutAtAWord() {
        let subject = SessionSummary(id: 1, title: "Audit the iOS app for parity with the PWA, then implement the findings as a series of slices", status: .needsInput)
        let line = LiveContext(sessions: [subject]).titleVariants(for: .listening)[0]
        XCTAssertTrue(line.hasPrefix("Listening · Audit the iOS app for parity with the PWA, then"), line)
        XCTAssertTrue(line.hasSuffix("…: needs input"), line)
    }

    func testTheScreenRebuildsOnlyWhenTheSubjectChanges() {
        let a = LiveContext(sessions: [SessionSummary(id: 1, title: "A", status: .running)])
        let b = LiveContext(sessions: [SessionSummary(id: 1, title: "A", status: .running)], activity: "Starting work…", needsYou: 4)
        XCTAssertFalse(a.differs(from: b), "the activity and the count are not in the line while there is a subject")
        let c = LiveContext(sessions: [SessionSummary(id: 1, title: "A", status: .needsInput)])
        XCTAssertTrue(a.differs(from: c), "the subject's status changed")
        let d = LiveContext(sessions: [SessionSummary(id: 2, title: "B", status: .running), SessionSummary(id: 1, title: "A", status: .running)])
        XCTAssertTrue(a.differs(from: d), "a newer subject")
        XCTAssertTrue(LiveContext(needsYou: 1).differs(from: LiveContext(needsYou: 2)), "with no subject the count is the line")
        XCTAssertFalse(LiveContext(needsYou: 1).differs(from: LiveContext(needsYou: 1)))
    }

    func testMutingRebuildsTheScreenBecauseMutedIsInTheTitleNotAStateOfItsOwn() {
        XCTAssertTrue(LiveContext(muted: true).differs(from: LiveContext(muted: false)))
        let subject = [SessionSummary(id: 1, title: "A", status: .running)]
        XCTAssertTrue(LiveContext(sessions: subject, muted: true).differs(from: LiveContext(sessions: subject)))
    }

    /// The regression test for the call screen CarPlay could not show: ten states, a muted twin
    /// of each, of which CarPlay keeps five — so *speaking* and *working* were never there to
    /// activate.
    func testTheCallScreenFitsTheFiveStatesCarPlayKeepsAndNamesOneForEveryCallState() {
        XCTAssertLessThanOrEqual(LiveCallScreen.states.count, LiveCallScreen.maximumStates)
        XCTAssertEqual(Set(LiveCallScreen.states.map(\.rawValue)).count, LiveCallScreen.states.count, "no two states share an identifier")
        let built = Set(LiveCallScreen.states.map(\.rawValue))
        for state in [LiveVoiceState.idle, .connecting, .listening, .thinking, .speaking, .working] {
            XCTAssertTrue(built.contains(LiveCallScreen.identifier(for: state)), "\(state) activates a state the screen has")
        }
        XCTAssertEqual(LiveCallScreen.states.first, .connecting, "the screen opens on connecting")
    }

    func testReferencedSessionIDsAreReadTheWayZimmersToolsWriteThem() {
        let output = """
        ## Quick Router session started

        - **ID:** 1101
        - **URL:** https://zimmer.example.com/sessions/1101
        See also session #1038 and https://zimmer.example.com/sessions/1035.
        """
        XCTAssertEqual(LiveReferencedSessions.ids(in: output), [1101, 1038, 1035])
        XCTAssertEqual(LiveReferencedSessions.ids(in: "nothing here"), [])
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
