import XCTest
@testable import ZimmerKit

/// The `gpt_live_claude` engine on the phone and in the car: what the app sends Zimmer, what it
/// reads back, and what it does with every GPT-Live event (the web dock's `GptLiveCall` rules).
final class GptLiveAPITests: XCTestCase {
    private func client(_ handlers: [ScriptedTransport.Handler]) -> (ZimmerHTTPClient, ScriptedTransport) {
        let transport = ScriptedTransport(handlers)
        return (ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport), transport)
    }

    private func body(_ request: HTTPRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])
    }

    func testAGptLiveCallIsGrantedWithNoSecretThenStartedDelegatedAndReported() async throws {
        let (api, transport) = client([
            { _ in Fixtures.json(200, ["engine": "gpt_live_claude", "model": "gpt-live-1", "telemetry": "info",
                                       "voice_engine": ["engine": "gpt_live_claude", "requested": "gpt_live_claude",
                                                        "warning": "gpt_live_claude has spent $8.10 of its $10.00 daily cap."]]) },
            { _ in Fixtures.json(200, ["session_id": "sess_1", "sdp": "v=0 answer", "model": "gpt-live-1"]) },
            { _ in Fixtures.json(200, ["text": "Two sessions are running.", "chunks": ["Two sessions are running."], "end_call": false, "rounds": 1]) },
            { _ in Fixtures.json(201, ["recorded": 1, "cost_usd": 0.05]) },
        ])

        let grant = try await api.liveCallGrant(7)
        XCTAssertTrue(grant.isGptLive)
        XCTAssertNil(grant.realtime)
        XCTAssertEqual(grant.model, "gpt-live-1")
        XCTAssertEqual(grant.telemetry, "info")
        XCTAssertEqual(grant.choice?.note, "gpt_live_claude has spent $8.10 of its $10.00 daily cap.", "a warning is shown, as on the dock")
        XCTAssertNil(grant.choice?.spokenFallback, "nothing fell back: nothing to say")
        let mint = try body(transport.sent[0])
        XCTAssertEqual(mint["engines"] as? [String], ["gpt_live_claude"])
        XCTAssertEqual(mint["listening_modes"] as? String, "1")

        let answer = try await api.startGptLiveSession(7, sdp: "v=0 offer")
        XCTAssertEqual(answer, GptLiveAnswer(sessionID: "sess_1", sdp: "v=0 answer", model: "gpt-live-1"))
        XCTAssertEqual(transport.sent[1].url.path, "/api/v1/live_conversations/7/gpt_live_session")
        XCTAssertEqual(try body(transport.sent[1])["sdp"] as? String, "v=0 offer")

        let delegation = try await api.answerLiveDelegation(7, delegationID: "item_d1", pendingUserText: "What's running?")
        XCTAssertEqual(delegation, LiveDelegation(chunks: ["Two sessions are running."]))
        XCTAssertEqual(transport.sent[2].url.path, "/api/v1/live_conversations/7/delegations")
        XCTAssertEqual(try body(transport.sent[2])["delegation_id"] as? String, "item_d1")
        XCTAssertEqual(try body(transport.sent[2])["pending_user_text"] as? String, "What's running?")

        try await api.reportLiveUsage(7, events: [LiveUsageEvent(engine: "gpt_live_claude", operation: "voice_session", key: "ios1.1", seconds: 60,
                                                                 details: ["partial": .bool(false)])])
        XCTAssertEqual(transport.sent[3].url.path, "/api/v1/live_conversations/7/usage")
        let event = try XCTUnwrap((try body(transport.sent[3])["events"] as? [[String: Any]])?.first)
        XCTAssertEqual(event["operation"] as? String, "voice_session")
        XCTAssertEqual(event["seconds"] as? Double, 60)
        XCTAssertEqual((event["details"] as? [String: Any])?["partial"] as? Bool, false)

        try await api.reportLiveUsage(7, events: [])
        XCTAssertEqual(transport.sent.count, 4, "nothing to report sends nothing")
    }

    func testAFallbackIsARealtimeSecretWithItsReasonToShowAndToSay() async throws {
        let (api, transport) = client([
            { _ in Fixtures.json(200, ["client_secret": "ek_1", "model": "gpt-realtime-2.1-mini",
                                       "websocket_url": "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini",
                                       "engine": "openai_realtime",
                                       "voice_engine": ["engine": "openai_realtime", "requested": "gpt_live_claude",
                                                        "fallback_reason": "Zimmer has no current Claude Code account"]]) },
            { _ in Fixtures.json(409, ["error": "Conflict", "message": "The next call runs on gpt_live_claude, which has no connection to pre-warm."]) },
        ])
        let grant = try await api.liveCallGrant(7)
        XCTAssertEqual(grant.realtime?.clientSecret, "ek_1")
        XCTAssertEqual(grant.choice?.note, "On OpenAI Realtime: Zimmer has no current Claude Code account.")
        XCTAssertEqual(grant.choice?.spokenFallback,
                       "(Zimmer: this call is on OpenAI Realtime, not the gpt_live_claude engine, because Zimmer has no current Claude Code account. Say that in one short sentence, then stop.)")

        await XCTAssertThrowsAsync(try await api.livePrewarmSecret(7), "Zimmer refuses to pre-warm Realtime for a GPT-Live call")
        XCTAssertEqual(LiveEngineChoice.spokenLine("GPT-Live could not start."),
                       "(Zimmer: GPT-Live could not start. Say that in one short sentence, then stop.)")
        let prewarm = try body(transport.sent[1])
        XCTAssertEqual(prewarm["engines"] as? [String], ["gpt_live_claude"], "the prewarm says what the app can run, so Zimmer can tell")
        XCTAssertEqual(prewarm["prewarm"] as? String, "1")
    }

    func testTheFakeRunsTheEngineTheSettingsPick() async throws {
        let fake = FakeZimmerAPI()
        let conversation = try await fake.startLiveConversation(.voice)
        let realtime = try await fake.liveCallGrant(conversation.id)
        XCTAssertFalse(realtime.isGptLive)
        XCTAssertNil(realtime.choice?.note)

        _ = try await fake.updateLiveSettings(["voice_engine": .string("gpt_live_claude")])
        let gptLive = try await fake.liveCallGrant(conversation.id)
        XCTAssertTrue(gptLive.isGptLive)
        let answer = try await fake.startGptLiveSession(conversation.id, sdp: "v=0")
        XCTAssertEqual(answer.sessionID, "sess_fixture")
        await XCTAssertThrowsAsync(try await fake.livePrewarmSecret(conversation.id), "no Realtime pre-warm for a GPT-Live call")

        let realtimeAfterAll = try await fake.liveCallGrant(conversation.id, engines: [])
        XCTAssertFalse(realtimeAfterAll.isGptLive, "GPT-Live could not start: the app asks again, able to run nothing else")
        XCTAssertEqual(realtimeAfterAll.choice?.note, "On OpenAI Realtime: this client cannot run gpt_live_claude.")

        let settings = try await fake.liveSettings()
        XCTAssertEqual(settings.fields(on: "engine").map(\.key), ["voice_engine", "voice_claude_model"])
    }
}

final class GptLiveConductorTests: XCTestCase {
    private func event(_ type: String, _ fields: [String: JSONValue] = [:]) -> JSONValue {
        .object(fields.merging(["type": .string(type)]) { $1 })
    }

    private func sent(_ effects: [GptLiveConductor.Effect]) -> [JSONValue] {
        effects.compactMap { if case let .send(event) = $0 { return event } else { return nil } }
    }

    private func records(_ effects: [GptLiveConductor.Effect]) -> [String] {
        effects.compactMap { if case let .record(role, text) = $0 { return "\(role.rawValue): \(text)" } else { return nil } }
    }

    private func reports(_ effects: [GptLiveConductor.Effect]) -> [LiveUsageEvent] {
        effects.compactMap { if case let .report(event) = $0 { return event } else { return nil } }
    }

    private func started(at now: TimeInterval = 0) -> GptLiveConductor {
        var conductor = GptLiveConductor(callKey: "k")
        conductor.sessionStarted(id: "sess_1")
        _ = conductor.handle(event("session.started", ["session": .object(["id": .string("sess_1")])]), at: now)
        return conductor
    }

    func testStartedIsTheCallUp() {
        var conductor = GptLiveConductor(callKey: "k")
        let effects = conductor.handle(event("session.started"), at: 10)
        XCTAssertEqual(effects, [.started, .state(.listening)])
    }

    func testTranscriptFragmentsAreOneTurnPerSpeakerRunAndTheFirstAnswerIsTimed() {
        var conductor = started()
        XCTAssertEqual(conductor.handle(event("session.input_transcript.delta", ["delta": .string("What's ")]), at: 1),
                       [.signal(.personTalking), .state(.listening)])
        _ = conductor.handle(event("session.input_transcript.delta", ["delta": .string("running?")]), at: 2)

        let answer = conductor.handle(event("session.output_transcript.delta", ["delta": .string("Two ")]), at: 2.9)
        XCTAssertEqual(records(answer), ["user: What's running?"], "the person's line is written when the answer starts")
        let latency = try? XCTUnwrap(reports(answer).first)
        XCTAssertEqual(latency?.operation, "turn_latency")
        XCTAssertEqual(latency?.firstAudioMs, 900)
        XCTAssertEqual(latency?.details?["delegated"], .bool(false))
        XCTAssertTrue(answer.contains(.firstAudio))
        XCTAssertTrue(answer.contains(.state(.speaking)))

        let more = conductor.handle(event("session.output_transcript.delta", ["delta": .string("sessions.")]), at: 3)
        XCTAssertTrue(reports(more).isEmpty, "one latency per turn")
        XCTAssertFalse(more.contains(.firstAudio), "the call's first audio is logged once")

        XCTAssertEqual(conductor.tick(at: 3.5), [], "still mid-answer")
        let done = conductor.tick(at: 4.3)
        XCTAssertEqual(records(done), ["assistant: Two sessions."])
        XCTAssertTrue(done.contains(.state(.listening)))
    }

    func testADelegationCarriesTheLineInFlightAndItsAnswerIsCommentary() {
        var conductor = started()
        _ = conductor.handle(event("session.input_transcript.delta", ["delta": .string("Start a session")]), at: 1)
        let delegation = conductor.handle(event("session.delegation.created", ["delegation": .object([
            "id": .string("item_d1"), "type": .string("delegation"), "target": .string("client")])]), at: 1.5)
        XCTAssertEqual(delegation, [.record(.user, "Start a session"), .signal(.personStopped),
                                    .delegate(id: "item_d1", pendingUserText: "Start a session"), .signal(.toolsRunning(1)), .state(.working)])

        let answered = conductor.delegated(id: "item_d1", answer: LiveDelegation(chunks: ["Started session 9.", "It's looking now."],
                                                                                 warning: "Past 80% of the cap."), failure: nil, at: 4)
        let events = sent(answered)
        XCTAssertEqual(events.map { $0["type"]?.string }, ["session.thinking.append", "session.commentary.append", "session.commentary.append"])
        XCTAssertEqual(events[0]["delegation_id"], .null)
        XCTAssertEqual(events[0]["content"]?.string, "Budget note from Zimmer: Past 80% of the cap.")
        XCTAssertEqual(events[1]["delegation_id"]?.string, "item_d1")
        XCTAssertEqual(events[2]["content"]?.string, "It's looking now.")
        XCTAssertEqual(Set(events.compactMap { $0["event_id"]?.string }).count, 3, "every client event has its own id")

        let again = conductor.delegated(id: "item_d2", answer: LiveDelegation(chunks: ["OK."], warning: "Past 80% of the cap."), failure: nil, at: 5)
        XCTAssertEqual(sent(again).map { $0["type"]?.string }, ["session.commentary.append"], "the warning goes once")

        let speaking = conductor.handle(event("session.output_transcript.delta", ["delta": .string("Started.")]), at: 6)
        XCTAssertEqual(reports(speaking).first?.details?["delegated"], .bool(true))

        XCTAssertEqual(conductor.handle(event("session.delegation.created", ["delegation": .object(["id": .string("r"), "target": .string("responses")])]), at: 7), [],
                       "only client delegations are Zimmer's")
    }

    func testAnUnreachableZimmerIsSaidNotSilent() {
        var conductor = started()
        let failed = conductor.delegated(id: "d", answer: nil, failure: "Zimmer answered 503", at: 1)
        XCTAssertEqual(sent(failed).first?["content"]?.string, "I couldn't do that: Zimmer answered 503.")
        let offline = conductor.delegated(id: "d", answer: nil, failure: nil, at: 1)
        XCTAssertEqual(sent(offline).first?["content"]?.string, "I couldn't reach Zimmer just now. Try again in a moment.")
    }

    func testEndCallHangsUpOnceTheGoodbyeHasBeenSaid() {
        var conductor = started()
        _ = conductor.handle(event("session.output_transcript.delta", ["delta": .string("One moment…")]), at: 1)
        _ = conductor.delegated(id: "d", answer: LiveDelegation(chunks: ["Hanging up now."], endCall: true), failure: nil, at: 1.5)
        XCTAssertTrue(conductor.hangingUp)
        // The filler line that was already sounding stops: not the goodbye, so the call stays.
        XCTAssertFalse(conductor.tick(at: 2.8).contains(.hangUp))
        _ = conductor.handle(event("session.output_transcript.delta", ["delta": .string("Bye!")]), at: 3)
        XCTAssertFalse(conductor.tick(at: 3.5).contains(.hangUp))
        let after = conductor.tick(at: 4.3)
        XCTAssertEqual(records(after), ["assistant: Bye!"])
        XCTAssertTrue(after.contains(.hangUp))
        XCTAssertFalse(conductor.tick(at: 20).contains(.hangUp), "once")
    }

    func testAGoodbyeThatNeverComesStillEndsTheCall() {
        var conductor = started()
        _ = conductor.delegated(id: "d", answer: LiveDelegation(chunks: ["The cap is reached."], endCall: true), failure: nil, at: 10)
        XCTAssertFalse(conductor.tick(at: 17).contains(.hangUp))
        XCTAssertTrue(conductor.tick(at: 18).contains(.hangUp))
    }

    /// Live conversation 38: "let's hang up now", "Okay, hanging up. Bye!", and the call stayed
    /// open, because GPT-Live answered without delegating the hang-up.
    func testAGoodbyeToThePersonsOwnHangUpEndsTheCallOnceSaid() {
        var conductor = started()
        _ = conductor.handle(event("session.input_transcript.delta", ["delta": .string("Alright, let's hang up now.")]), at: 1)
        _ = conductor.handle(event("session.output_transcript.delta", ["delta": .string("Okay, hanging up. Bye!")]), at: 1.5)
        XCTAssertFalse(conductor.tick(at: 2).contains(.hangUp), "not while the goodbye is still being said")
        let after = conductor.tick(at: 2.8)
        XCTAssertEqual(records(after), ["assistant: Okay, hanging up. Bye!"])
        XCTAssertTrue(after.contains(.hangUp))
    }

    func testAGoodbyeToDontOrHowOrAnotherLineLeavesTheCallOpen() {
        for (asked, said) in [("Tell Sam I said bye, but don't hang up.", "Will do. Bye to Sam, then."),
                              ("How do I hang up?", "Just say hang up, or tap End."),
                              ("What's running?", "Two sessions. Bye!")] {
            var conductor = started()
            _ = conductor.handle(event("session.input_transcript.delta", ["delta": .string(asked)]), at: 1)
            _ = conductor.handle(event("session.output_transcript.delta", ["delta": .string(said)]), at: 1.5)
            XCTAssertFalse(conductor.tick(at: 2.8).contains(.hangUp), asked)
            XCTAssertFalse(conductor.tick(at: 30).contains(.hangUp), asked)
        }
    }

    func testAGoodbyeInTheAnswerToADelegatedLineIsTheBackendsToActOn() {
        var conductor = started()
        _ = conductor.handle(event("session.input_transcript.delta", ["delta": .string("Send Sam a message saying goodbye.")]), at: 1)
        _ = conductor.handle(event("session.delegation.created", ["delegation": .object(["id": .string("d"), "target": .string("client")])]), at: 1.2)
        _ = conductor.delegated(id: "d", answer: LiveDelegation(chunks: ["Sent. Your goodbye message is on its way."], endCall: false), failure: nil, at: 3)
        _ = conductor.handle(event("session.output_transcript.delta", ["delta": .string("Sent. Your goodbye message is on its way.")]), at: 3.2)
        XCTAssertFalse(conductor.tick(at: 4.5).contains(.hangUp))
        XCTAssertFalse(conductor.tick(at: 30).contains(.hangUp))
    }

    func testALineIsSpentOnceAnswered() {
        var conductor = started()
        _ = conductor.handle(event("session.input_transcript.delta", ["delta": .string("Hang up.")]), at: 1)
        _ = conductor.handle(event("session.output_transcript.delta", ["delta": .string("Are you sure?")]), at: 1.5)
        XCTAssertFalse(conductor.tick(at: 2.8).contains(.hangUp))
        _ = conductor.handle(event("session.output_transcript.delta", ["delta": .string("Okay, bye then.")]), at: 5)
        XCTAssertFalse(conductor.tick(at: 6.5).contains(.hangUp))
    }

    func testAGoodbyeSaidOverARunningDelegationWaitsForTheBackend() {
        var conductor = started()
        _ = conductor.handle(event("session.input_transcript.delta", ["delta": .string("Hang up.")]), at: 1)
        _ = conductor.handle(event("session.delegation.created", ["delegation": .object(["id": .string("d"), "target": .string("client")])]), at: 1.2)
        _ = conductor.handle(event("session.output_transcript.delta", ["delta": .string("Okay, bye!")]), at: 1.3)
        XCTAssertFalse(conductor.tick(at: 2.8).contains(.hangUp), "Claude is still working on it")
        _ = conductor.delegated(id: "d", answer: LiveDelegation(chunks: ["Okay, hanging up."], endCall: true), failure: nil, at: 3)
        _ = conductor.handle(event("session.output_transcript.delta", ["delta": .string("Hanging up now.")]), at: 3.2)
        XCTAssertTrue(conductor.tick(at: 4.5).contains(.hangUp))
    }

    func testTheHangUpRuleNeedsTheAskAndTheGoodbye() {
        XCTAssertTrue(GptLiveConductor.endsTheCall(asked: "Alright, let's hang up now", said: "Okay, hanging up. Bye!"))
        XCTAssertTrue(GptLiveConductor.endsTheCall(asked: "I thought I told you to hang up", said: "You're right. Bye."))
        XCTAssertTrue(GptLiveConductor.endsTheCall(asked: "Zimmer, end the call", said: "Ending the call. Talk soon."))
        XCTAssertTrue(GptLiveConductor.endsTheCall(asked: "Stop listening", said: "Goodbye!"))
        XCTAssertTrue(GptLiveConductor.endsTheCall(asked: "Okay bye", said: "Bye!"))
        XCTAssertTrue(GptLiveConductor.endsTheCall(asked: "Pause", said: "Hanging up. Call again when you're ready."))
        XCTAssertFalse(GptLiveConductor.endsTheCall(asked: "Not yet, don't hang up", said: "Bye"))
        XCTAssertFalse(GptLiveConductor.endsTheCall(asked: "How do I hang up?", said: "Say hang up. Bye is fine too."))
        XCTAssertFalse(GptLiveConductor.endsTheCall(asked: "What's running?", said: "Two sessions. Bye!"))
        XCTAssertFalse(GptLiveConductor.endsTheCall(asked: "Don\u{2019}t hang up yet", said: "Okay. Bye for now isn't happening."))
        XCTAssertFalse(GptLiveConductor.endsTheCall(asked: "Hang up", said: "Are you sure?"))
        XCTAssertFalse(GptLiveConductor.endsTheCall(asked: "Hang up", said: "Hanging upstairs is not something I do."))
    }

    func testTheSessionIsReportedEveryMinuteAndTheRestFromClosedUsage() {
        var conductor = started(at: 100)
        let minute = conductor.tick(at: 160)
        XCTAssertEqual(reports(minute).map(\.operation), ["call", "voice_session"])
        XCTAssertEqual(reports(minute).map(\.seconds), [60, 60])
        XCTAssertEqual(reports(minute).map(\.key), ["k.1", "k.2"])
        XCTAssertEqual(reports(minute)[1].details?["session_id"], .string("sess_1"))

        XCTAssertEqual(conductor.close(at: 190).compactMap { if case let .send(e) = $0 { return e["type"]?.string } else { return nil } },
                       ["session.close"])
        XCTAssertEqual(conductor.tick(at: 191), [], "waiting for session.closed")
        let closed = conductor.handle(event("session.closed", ["reason": .string("close_requested"), "usage": .object(["seconds": .number(95)])]), at: 191)
        let rows = reports(closed)
        XCTAssertEqual(rows.map(\.operation), ["call", "voice_session"])
        XCTAssertEqual(rows[0].seconds, 30, "the call's length stops when the person hung up, not when OpenAI said closed")
        XCTAssertEqual(rows[1].seconds, 35, "GPT-Live's own total, less what was reported")
        XCTAssertEqual(rows[1].details?["from_usage"], .bool(true))
        XCTAssertEqual(closed.last, .closed)
        XCTAssertTrue(conductor.ended)
        XCTAssertEqual(conductor.finish(at: 200), [], "finished once")
    }

    func testAClosedThatNeverComesFinishesAfterItsGrace() {
        var conductor = started(at: 0)
        _ = conductor.handle(event("session.input_transcript.delta", ["delta": .string("bye")]), at: 5)
        _ = conductor.close(at: 10)
        XCTAssertEqual(conductor.tick(at: 12), [])
        let late = conductor.tick(at: 13)
        XCTAssertEqual(records(late), ["user: bye"])
        XCTAssertEqual(reports(late).map(\.operation), ["call", "voice_session"])
        XCTAssertEqual(reports(late)[1].seconds, 13, "no usage from OpenAI: the seconds this call saw")
        XCTAssertEqual(reports(late)[1].details?["from_usage"], .bool(false))
        XCTAssertEqual(late.last, .closed)
    }

    func testAnErrorIsShownAndTheCallCarriesOn() {
        var conductor = started()
        XCTAssertEqual(conductor.handle(event("error", ["error": .object(["message": .string("bad commentary")])]), at: 1), [.failure("bad commentary"), .signal(.noAnswerComing), .state(.listening)])
        XCTAssertFalse(conductor.ended)
    }

    // MARK: - Cues

    /// What a driver hears: every state and signal the conductor gives, through the same
    /// `LiveCueDirector` a Realtime call uses, as `LiveCall` performs them.
    private struct Ear {
        var director = LiveCueDirector()
        var actions: [LiveCueDirector.Action] = []

        mutating func hear(_ effects: [GptLiveConductor.Effect]) -> [LiveCueDirector.Action] {
            var heard: [LiveCueDirector.Action] = []
            for effect in effects {
                switch effect {
                case let .state(state): heard += director.transition(to: state)
                case let .signal(signal): heard += director.receive(signal)
                default: break
                }
            }
            actions += heard
            return heard
        }
    }

    /// A call just up, and the ear that heard it connect.
    private func call() -> (GptLiveConductor, Ear) {
        var conductor = GptLiveConductor(callKey: "k")
        var ear = Ear()
        XCTAssertEqual(ear.hear(conductor.handle(event("session.started"), at: 0)), [.play(.connected)])
        return (conductor, ear)
    }

    private func input(_ text: String) -> JSONValue { event("session.input_transcript.delta", ["delta": .string(text)]) }
    private func output(_ text: String) -> JSONValue { event("session.output_transcript.delta", ["delta": .string(text)]) }
    private func delegation(_ id: String) -> JSONValue {
        event("session.delegation.created", ["delegation": .object(["id": .string(id), "target": .string("client")])])
    }

    func testTheCallUpSoundsConnected() {
        var conductor = GptLiveConductor(callKey: "k")
        var ear = Ear()
        XCTAssertEqual(ear.hear(conductor.handle(event("session.started"), at: 0)), [.play(.connected)])
    }

    func testALineGoneQuietWithNoAnswerIsHeardThenThinking() {
        var (conductor, ear) = call()
        XCTAssertEqual(ear.hear(conductor.handle(input("What's "), at: 1)), [.stopCues], "the person talking silences every cue")
        XCTAssertEqual(ear.hear(conductor.handle(input("running?"), at: 1.4)), [])
        XCTAssertEqual(ear.hear(conductor.tick(at: 1.9)), [], "a pause shorter than heardIdle is still the person talking")
        let heard = conductor.tick(at: 1.4 + GptLiveConductor.heardIdle)
        XCTAssertEqual(heard, [.signal(.personStopped), .state(.thinking), .signal(.heardPerson)])
        XCTAssertEqual(ear.hear(heard), [.startLoop(.thinking), .play(.heard, after: LiveCue.heardLead)])
        XCTAssertEqual(ear.hear(conductor.tick(at: 3)), [], "heard once")
        XCTAssertEqual(ear.hear(conductor.handle(output("Two."), at: 3.2)), [.stopCues], "the answer starting stops the thinking loop")
    }

    func testAnAnswerBeforeHeardIdleGetsNoHeard() {
        var (conductor, ear) = call()
        _ = ear.hear(conductor.handle(input("Hi"), at: 1))
        let answer = conductor.handle(output("Hey."), at: 1.3)
        XCTAssertEqual(Array(answer.suffix(2)), [.state(.speaking), .signal(.personStopped)])
        _ = ear.hear(answer)
        XCTAssertTrue(conductor.tick(at: 5).allSatisfy { if case .signal = $0 { return false } else { return true } })
        XCTAssertFalse(ear.actions.contains(.play(.heard, after: LiveCue.heardLead)))
    }

    func testADelegationIsTheWorkingLoopThroughTheFillerUntilClaudeAnswers() {
        var (conductor, ear) = call()
        _ = ear.hear(conductor.handle(input("Start a session"), at: 1))
        XCTAssertEqual(ear.hear(conductor.handle(delegation("d1"), at: 1.3)), [.startLoop(.working)])

        // GPT-Live says its filler over the wait, then goes quiet: the working loop comes back.
        XCTAssertEqual(ear.hear(conductor.handle(output("One moment."), at: 1.5)), [.stopCues])
        XCTAssertEqual(ear.hear(conductor.tick(at: 1.5 + GptLiveConductor.spokenIdle)), [.startLoop(.working)],
                       "Claude is still working after the filler")

        // Claude answers: thinking until GPT-Live starts saying it.
        let answered = conductor.delegated(id: "d1", answer: LiveDelegation(chunks: ["Started session 9."]), failure: nil, at: 8)
        XCTAssertTrue(answered.contains(.signal(.toolsRunning(0))))
        XCTAssertEqual(ear.hear(answered), [.stopLoop, .startLoop(.thinking)])
        XCTAssertEqual(ear.hear(conductor.handle(output("Started."), at: 9)), [.stopCues])
    }

    func testAnAnswerThatArrivesWhileGptLiveTalksStartsNoThinking() {
        var conductor = started()
        _ = conductor.handle(delegation("d1"), at: 1)
        _ = conductor.handle(output("One moment."), at: 1.2)
        let answered = conductor.delegated(id: "d1", answer: LiveDelegation(chunks: ["Done."]), failure: nil, at: 1.5)
        XCTAssertFalse(answered.contains(.state(.thinking)))
    }

    func testAFailedDelegationSoundsFailed() {
        var (conductor, ear) = call()
        _ = ear.hear(conductor.handle(delegation("d1"), at: 1))
        let failed = conductor.delegated(id: "d1", answer: nil, failure: "Zimmer answered 503", at: 3)
        XCTAssertEqual(Array(failed.prefix(3)), [.signal(.toolsRunning(0)), .state(.thinking), .signal(.actionFailed)])
        // Thinking until GPT-Live says the failure, and the failed notes now.
        XCTAssertEqual(ear.hear(failed), [.stopLoop, .startLoop(.thinking), .play(.failed)])
    }

    func testAStrayErrorWhileClaudeWorksSoundsNothing() {
        var (conductor, ear) = call()
        _ = ear.hear(conductor.handle(delegation("d1"), at: 1))
        let error = conductor.handle(event("error", ["error": .object(["message": .string("bad commentary")])]), at: 2)
        XCTAssertEqual(error, [.failure("bad commentary")])
        XCTAssertEqual(ear.hear(error), [])
        // So the delegation's own failure still sounds.
        XCTAssertTrue(ear.hear(conductor.delegated(id: "d1", answer: nil, failure: nil, at: 3)).contains(.play(.failed)))
    }

    func testAnErrorWhileThinkingAfterHeardFailsAndListens() {
        var (conductor, ear) = call()
        _ = ear.hear(conductor.handle(input("Hm"), at: 1))
        _ = ear.hear(conductor.tick(at: 2))
        let error = conductor.handle(event("error", ["error": .object(["message": .string("oops")])]), at: 3)
        XCTAssertEqual(ear.hear(error), [.play(.failed), .stopLoop])
    }

    func testThePersonCarryingOnAfterHeardIsTalkingAgainThenHeardAgain() {
        var (conductor, ear) = call()
        _ = ear.hear(conductor.handle(input("Start"), at: 1))
        _ = ear.hear(conductor.tick(at: 2))
        XCTAssertEqual(ear.hear(conductor.handle(input(" a session"), at: 2.5)), [.stopCues])
        XCTAssertEqual(ear.hear(conductor.tick(at: 3.2)), [.startLoop(.thinking), .play(.heard, after: LiveCue.heardLead)])
    }

    func testTalkingOverClaudeStopsTheWorkingLoopUntilThePersonStops() {
        var (conductor, ear) = call()
        _ = ear.hear(conductor.handle(delegation("d1"), at: 1))
        XCTAssertEqual(ear.hear(conductor.handle(input("Also"), at: 2)), [.stopCues])
        // Heard, and still working: the working loop, not thinking.
        XCTAssertEqual(ear.hear(conductor.tick(at: 3)), [.startLoop(.working), .play(.heard, after: LiveCue.heardLead)])
    }

    func testThinkingThatGptLiveNeverAnswersGoesBackToListeningQuietly() {
        var (conductor, ear) = call()
        _ = ear.hear(conductor.handle(input("Hm"), at: 1))
        _ = ear.hear(conductor.tick(at: 2))
        XCTAssertEqual(conductor.tick(at: 2 + GptLiveConductor.answerGrace - 0.1), [])
        let gaveUp = conductor.tick(at: 2 + GptLiveConductor.answerGrace)
        XCTAssertEqual(gaveUp, [.state(.listening)])
        XCTAssertEqual(ear.hear(gaveUp), [.stopLoop], "no failed: GPT-Live chose not to answer")
    }

    func testAnAnswerWithNothingToSayIsListening() {
        var conductor = started()
        _ = conductor.handle(delegation("d1"), at: 1)
        let empty = conductor.delegated(id: "d1", answer: LiveDelegation(chunks: [""]), failure: nil, at: 2)
        XCTAssertEqual(empty, [.signal(.toolsRunning(0)), .state(.listening)])
    }

    func testTwoDelegationsKeepWorkingUntilBothAreBack() {
        var conductor = started()
        _ = conductor.handle(delegation("d1"), at: 1)
        XCTAssertTrue(conductor.handle(delegation("d2"), at: 2).contains(.signal(.toolsRunning(2))))
        let first = conductor.delegated(id: "d1", answer: LiveDelegation(chunks: ["One."]), failure: nil, at: 3)
        XCTAssertTrue(first.contains(.signal(.toolsRunning(1))))
        XCTAssertFalse(first.contains(.state(.thinking)), "one still running")
        XCTAssertTrue(conductor.delegated(id: "d2", answer: LiveDelegation(chunks: ["Two."]), failure: nil, at: 4).contains(.state(.thinking)))
    }

    func testBilledSecondsReadsEverySpelling() {
        XCTAssertEqual(GptLiveConductor.billedSeconds(.object(["seconds": .number(12)])), 12)
        XCTAssertEqual(GptLiveConductor.billedSeconds(.object(["duration_ms": .number(1_500)])), 1.5)
        XCTAssertNil(GptLiveConductor.billedSeconds(.object([:])))
        XCTAssertNil(GptLiveConductor.billedSeconds(nil))
    }
}
