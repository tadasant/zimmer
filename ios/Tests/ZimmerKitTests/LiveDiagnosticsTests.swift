import XCTest
@testable import ZimmerKit

/// A Live voice call's telemetry, its cues and its microphone watchdog: what a call in the car
/// reports, how it sounds, and how its turn always ends.
final class LiveDiagnosticsTests: XCTestCase {
    private func event(_ json: String) -> JSONValue { JSONValue.parse(json)! }

    private final class Box<T>: @unchecked Sendable {
        let lock = NSLock()
        var value: T
        init(_ value: T) { self.value = value }
        func update(_ change: (inout T) -> Void) { lock.withLock { change(&value) } }
        var current: T { lock.withLock { value } }
    }

    private func telemetry(defaults: UserDefaults? = nil, sink: LiveTelemetry.Sink? = nil) -> LiveTelemetry {
        let clock = Box<TimeInterval>(100)
        return LiveTelemetry(client: LiveTelemetryClient(surface: "carplay", appVersion: "1.5.0", appBuild: "212", os: "iOS 26.4", device: "iPhone17,1"),
                             defaults: defaults, now: { Date(timeIntervalSince1970: 1_793_282_400) },
                             uptime: { clock.update { $0 += 0.25 }; return clock.current }, autoFlush: false, sink: sink)
    }

    // MARK: - Telemetry

    func testEventsBelowTheThresholdCostAComparisonAndNeverBuildTheirFields() {
        let log = telemetry()
        log.adopt("info")
        let built = Box(false)
        log.track(LiveEvent(.debug, "vad.speech_started") { built.update { $0 = true }; return [:] })
        XCTAssertFalse(built.current, "a debug event under an info threshold is not built")
        XCTAssertEqual(log.pending, 0)
        log.track(LiveEvent(.error, "call.failed"))
        XCTAssertEqual(log.pending, 1, "an error passes every level but off")
        log.adopt("off")
        XCTAssertEqual(log.pending, 0, "off empties what is waiting")
        log.track(LiveEvent(.error, "call.failed"))
        XCTAssertEqual(log.pending, 0)
    }

    func testTheLevelIsVerboseUntilZimmerSaysOtherwiseAndIsKeptForTheNextLaunch() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "live-telemetry-\(UUID().uuidString)"))
        XCTAssertEqual(telemetry(defaults: defaults).threshold, .debug)
        telemetry(defaults: defaults).adopt("warn")
        XCTAssertEqual(telemetry(defaults: defaults).threshold, .warn)
        telemetry(defaults: defaults).adopt("off")
        XCTAssertNil(telemetry(defaults: defaults).threshold)
    }

    func testEachEventCarriesItsCallItsOrderAndBothClocks() async throws {
        let sent = Box<[LiveTelemetryBatch]>([])
        let log = telemetry { batch in sent.update { $0.append(batch) }; return LiveTelemetryAnswer(accepted: batch.events.count, telemetry: "debug") }
        log.track(LiveEvent(.info, "carplay.scene_connected"))
        let call = log.beginCall(conversation: 42)
        log.track(.connected(sinceStart: 0.812, listening: "always", gated: false))
        log.endCall()
        await log.send()

        let batch = try XCTUnwrap(sent.current.first)
        XCTAssertEqual(batch.client.surface, "carplay")
        XCTAssertEqual(batch.events.map(\.seq), [1, 2])
        XCTAssertEqual(batch.events.map(\.callID), [nil, call])
        XCTAssertEqual(batch.events[1].conversationID, 42)
        XCTAssertEqual(batch.events[1].at, "2026-10-29T14:00:00.000Z")
        XCTAssertLessThan(batch.events[0].monoMs, batch.events[1].monoMs)
        XCTAssertEqual(batch.events[1].fields["since_start_ms"], .number(812))
        XCTAssertNil(batch.events[1].fields["absent"], "a nil field is left out")
        XCTAssertEqual(log.pending, 0)
    }

    func testTheBufferIsCappedAndWhatItDroppedIsCountedOnTheNextBatch() async throws {
        let sent = Box<[LiveTelemetryBatch]>([])
        let log = telemetry { batch in sent.update { $0.append(batch) }; return LiveTelemetryAnswer(accepted: batch.events.count, telemetry: nil) }
        for _ in 0..<(LiveTelemetry.capacity + 20) { log.track(LiveEvent(.debug, "vad.speech_started")) }
        XCTAssertEqual(log.pending, LiveTelemetry.capacity)
        await log.send()
        let batch = try XCTUnwrap(sent.current.first)
        XCTAssertEqual(batch.dropped, 20)
        XCTAssertEqual(batch.events.first?.seq, 21, "the oldest go first")
        XCTAssertEqual(batch.events.count, 100, "a batch is at most 100")
    }

    func testABatchThatFailsToSendComesBackForTheNextTryAndTheAnswerSetsTheLevel() async {
        let fail = Box(true)
        let log = telemetry { batch in
            if fail.current { throw ZimmerError.http(status: 502, message: nil) }
            return LiveTelemetryAnswer(accepted: batch.events.count, telemetry: "warn")
        }
        log.track(LiveEvent(.info, "call.connected"))
        await log.send()
        XCTAssertEqual(log.pending, 1, "kept for the next try")
        fail.update { $0 = false }
        await log.send()
        XCTAssertEqual(log.pending, 0)
        XCTAssertEqual(log.threshold, .warn, "turned down on the Live settings page: the app follows from this answer")
    }

    func testABatchIsWhatTheServerReads() async throws {
        let transport = ScriptedTransport([{ _ in Fixtures.json(202, ["accepted": 2, "filtered": 0, "telemetry": "info"]) }])
        let api = ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport)
        let log = telemetry { try await api.reportLiveTelemetry($0) }
        log.beginCall(conversation: 42)
        log.track(.connected(sinceStart: 0.812, listening: "always", gated: false))
        log.track(.micStalled(afterMs: 310))
        await log.send()

        let request = try XCTUnwrap(transport.sent.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.path, "/api/v1/live/telemetry")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])
        let events = try XCTUnwrap(body["events"] as? [[String: Any]])
        XCTAssertEqual(events.map { $0["name"] as? String }, ["call.connected", "mic.stalled"])
        XCTAssertEqual(events[0]["level"] as? String, "info")
        XCTAssertEqual(events[0]["conversation_id"] as? Int, 42)
        XCTAssertEqual((events[0]["fields"] as? [String: Any])?["since_start_ms"] as? Int, 812)
        XCTAssertEqual((body["client"] as? [String: Any])?["app_build"] as? String, "212")
        XCTAssertEqual(log.threshold, .info)
        if let path = ProcessInfo.processInfo.environment["ZIMMER_TELEMETRY_SAMPLE"] {
            try request.body?.write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: - The call's timeline

    func testTheTimelineReportsTurnDetectionAsAppliedAndTheEndOfSpeechToFirstAudio() {
        var timeline = LiveCallTimeline()
        timeline.started(at: 10)
        let session = timeline.observe(event(#"""
        {"type":"session.created","session":{"model":"gpt-realtime-2.1-mini","audio":{"input":{"format":{"type":"audio/pcm","rate":24000},
         "turn_detection":{"type":"semantic_vad","eagerness":"auto","create_response":true,"interrupt_response":true},
         "transcription":{"model":"gpt-4o-mini-transcribe"}}}}}
        """#), at: 10.9)
        XCTAssertEqual(session.map(\.name), ["realtime.session_created"])
        let fields = session[0].fields()
        XCTAssertEqual(fields["turn_detection"], .string("semantic_vad"))
        XCTAssertEqual(fields["create_response"], .bool(true))
        XCTAssertEqual(fields["noise_reduction"], .string("off"))
        XCTAssertEqual(fields["since_start_ms"], .number(900))

        _ = timeline.observe(event(#"{"type":"input_audio_buffer.speech_started","audio_start_ms":1200}"#), at: 12)
        let stopped = timeline.observe(event(#"{"type":"input_audio_buffer.speech_stopped","audio_end_ms":3400}"#), at: 14.2)
        XCTAssertEqual(stopped[0].fields()["speech_ms"], .number(2_200))
        _ = timeline.observe(event(#"{"type":"response.created"}"#), at: 14.5)
        let first = timeline.observe(event(#"{"type":"response.output_audio.delta","item_id":"r1","delta":"AAA="}"#), at: 15.1)
        XCTAssertEqual(first.map(\.name), ["response.first_audio"])
        XCTAssertEqual(first[0].level, .info)
        XCTAssertEqual(first[0].fields()["since_speech_end_ms"], .number(900))
        XCTAssertEqual(timeline.observe(event(#"{"type":"response.output_audio.delta","item_id":"r1","delta":"AAA="}"#), at: 15.2).count, 0,
                       "never per audio chunk")
        let done = timeline.observe(event(#"{"type":"response.done","response":{"status":"completed","output":[]}}"#), at: 17)
        XCTAssertEqual(done[0].fields()["had_audio"], .bool(true))
        XCTAssertEqual(done[0].fields()["audio_ms"], .number(0), "two samples, under a millisecond at 24 kHz")
        let error = timeline.observe(event(#"{"type":"error","error":{"type":"invalid_request_error","code":"x","message":"Bad"}}"#), at: 18)
        XCTAssertEqual(error[0].level, .error)
        XCTAssertEqual(timeline.summary["turns"], .number(1))
    }

    func testTheOutputCapOpenAIAppliedIsReported() {
        var timeline = LiveCallTimeline()
        let created = timeline.observe(event(#"{"type":"session.created","session":{"max_output_tokens":1024}}"#), at: 1)
        XCTAssertEqual(created[0].fields()["max_output_tokens"], .number(1_024))
        let updated = timeline.observe(event(#"{"type":"session.updated","session":{"max_output_tokens":"inf"}}"#), at: 2)
        XCTAssertEqual(updated[0].fields()["max_output_tokens"], .string("inf"))
    }

    func testAResponseTheCapCutOffIsAWarningAtEveryLevel() {
        var timeline = LiveCallTimeline()
        _ = timeline.observe(event(#"{"type":"response.created"}"#), at: 1)
        let cut = timeline.observe(event(#"{"type":"response.done","response":{"status":"incomplete","status_details":{"reason":"max_output_tokens"},"output":[{"type":"function_call"}]}}"#), at: 3)
        XCTAssertEqual(cut[0].name, "response.done")
        XCTAssertEqual(cut[0].level, .warn, "kept with telemetry turned down: a cut reply or tool call is a problem")
        XCTAssertEqual(cut[0].fields()["reason"], .string("max_output_tokens"))
        _ = timeline.observe(event(#"{"type":"response.created"}"#), at: 4)
        let talkedOver = timeline.observe(event(#"{"type":"response.done","response":{"status":"cancelled","status_details":{"reason":"turn_detected"},"output":[]}}"#), at: 5)
        XCTAssertEqual(talkedOver[0].level, .debug, "being talked over is a call working")
    }

    func testAReplysLengthAndWhereItWasCutAreLogged() {
        var timeline = LiveCallTimeline()
        _ = timeline.observe(event(#"{"type":"response.created"}"#), at: 1)
        let second = Data(count: 48_000).base64EncodedString()
        _ = timeline.observe(event(#"{"type":"response.output_audio.delta","item_id":"r1","delta":"\#(second)"}"#), at: 1.1)
        _ = timeline.observe(event(#"{"type":"response.output_audio.delta","item_id":"r1","delta":"\#(second)"}"#), at: 1.2)
        let done = timeline.observe(event(#"{"type":"response.done","response":{"status":"completed","output":[]}}"#), at: 1.5)
        XCTAssertEqual(done[0].fields()["audio_ms"], .number(2_000), "two seconds of reply, generated in half a second")
        XCTAssertEqual(done[0].fields()["duration_ms"], .number(500))

        _ = timeline.observe(event(#"{"type":"response.created"}"#), at: 2)
        let next = timeline.observe(event(#"{"type":"response.done","response":{"status":"completed","output":[]}}"#), at: 2.1)
        XCTAssertEqual(next[0].fields()["audio_ms"], .number(0), "counted per response")

        let cut = LiveEvent.replyInterrupted(.init(itemID: "r1", audioMs: 2_000, heardMs: 750))
        XCTAssertEqual(cut.name, "reply.interrupted")
        XCTAssertEqual(cut.level, .info)
        XCTAssertEqual(cut.fields(), ["item_id": .string("r1"), "audio_ms": .number(2_000), "heard_ms": .number(750)])

        let truncated = timeline.observe(event(#"{"type":"conversation.item.truncated","item_id":"r1","audio_end_ms":750}"#), at: 3)
        XCTAssertEqual(truncated.map(\.name), ["reply.truncated"])
        XCTAssertEqual(truncated[0].fields()["audio_end_ms"], .number(750))
    }

    func testALineAGatedCallDroppedIsAWarningNamingTheMode() {
        let dropped = LiveEvent.lineHeard(respond: false, dropped: true, ms: 0.4, listening: "wake_word")
        XCTAssertEqual(dropped.level, .warn, "kept at every level but off: the person got no answer")
        XCTAssertEqual(dropped.fields()["listening"], .string("wake_word"))
        XCTAssertEqual(LiveEvent.lineHeard(respond: true, dropped: false, ms: 0.4, listening: "dynamic").level, .debug)
    }

    func testAChangeOfModeMidCallIsLoggedWithBothSides() {
        let changed = LiveEvent.listeningChanged(from: "dynamic", to: "always")
        XCTAssertEqual(changed.name, "listening.changed")
        XCTAssertEqual(changed.level, .info)
        XCTAssertEqual(changed.fields()["from"], .string("dynamic"))
        XCTAssertEqual(changed.fields()["to"], .string("always"))
    }

    func testATranscriptIsReportedByItsLengthNeverItsWords() {
        var timeline = LiveCallTimeline()
        let line = timeline.observe(event(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"merge the docs fix"}"#), at: 1)
        XCTAssertEqual(line[0].fields(), ["characters": .number(18)])
    }

    // MARK: - End of speech

    func testTheEndOfSpeechPutsTheCallToWorkAtOnce() {
        var conductor = RealtimeConductor()
        XCTAssertEqual(conductor.handle(event(#"{"type":"input_audio_buffer.speech_started"}"#)), [.interrupt(arriving: nil), .signal(.personTalking), .state(.listening)])
        XCTAssertEqual(conductor.handle(event(#"{"type":"input_audio_buffer.speech_stopped","audio_end_ms":2000}"#)),
                       [.signal(.personStopped), .state(.thinking), .signal(.heardPerson)],
                       "the thinking cue starts the moment the person stops talking")
        var gated = RealtimeConductor(listening: "wake_word")
        _ = gated.handle(event(#"{"type":"input_audio_buffer.speech_stopped"}"#))
        XCTAssertEqual(gated.heard(itemID: "u1", respond: false),
                       [.send(.object(["type": .string("conversation.item.delete"), "item_id": .string("u1")])), .state(.listening)],
                       "a line not meant for Zimmer puts the call back to listening, not stuck working on it")
    }

    func testNoAnswerComingPutsTheCallBackToListeningSoTheTickNeverRunsOn() {
        var conductor = RealtimeConductor()
        _ = conductor.handle(event(#"{"type":"input_audio_buffer.speech_stopped"}"#))
        XCTAssertEqual(conductor.handle(event(#"{"type":"error","error":{"message":"Refused"}}"#)),
                       [.failure("Refused"), .signal(.noAnswerComing), .state(.listening)], "an error with nothing running: no answer is coming")
        _ = conductor.handle(event(#"{"type":"response.created"}"#))
        XCTAssertEqual(conductor.handle(event(#"{"type":"error","error":{"message":"Bad truncate"}}"#)), [.failure("Bad truncate")],
                       "an error beside a running response leaves it be")
        XCTAssertEqual(conductor.handle(event(#"{"type":"response.done","response":{"status":"cancelled","output":[]}}"#)), [.state(.listening)])
        _ = conductor.handle(event(#"{"type":"response.created"}"#))
        XCTAssertEqual(conductor.handle(event(#"{"type":"response.done","response":{"status":"failed","status_details":{"error":{"message":"x"}}}}"#)),
                       [.failure("x"), .state(.listening), .signal(.actionFailed)], "said once")

        var director = LiveCueDirector()
        _ = director.transition(to: .listening)
        _ = director.transition(to: .thinking)
        XCTAssertEqual(director.loopTimedOut(), [.stopLoop, .play(.failed)], "giving up is said out loud, not left as silence")
        XCTAssertEqual(director.loopTimedOut(), [])
    }

    func testTheGateStaysClosedForTheRoutesLatency() {
        var gate = LiveCueGate()
        gate.latency = 0.2
        gate.oneShot(.connected, at: 10)
        let end = 10 + LiveCue.connected.duration + LiveCueGate.tail
        XCTAssertTrue(gate.closes(end + 0.1, length: 0.02), "a car's 200 ms latency: the ding is still coming back through the mic")
        XCTAssertFalse(gate.closes(end + 0.25, length: 0.02))
    }

    func testAFlushDuringASendIsSentRightAfterIt() async {
        let sent = Box<[Int]>([])
        let log = telemetry()
        let release = Box(false)
        log.setSink { batch in
            sent.update { $0.append(batch.events.count) }
            while !release.current { try await Task.sleep(for: .milliseconds(5)) }
            return LiveTelemetryAnswer(accepted: batch.events.count, telemetry: nil)
        }
        log.track(LiveEvent(.info, "call.connected"))
        let first = Task { await log.send() }
        while sent.current.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        log.track(LiveEvent(.info, "call.ended"))
        await log.send()
        XCTAssertEqual(log.pending, 1, "a batch is out: this one waits")
        release.update { $0 = true }
        await first.value
        XCTAssertEqual(sent.current, [1, 1], "and goes as soon as the first is answered")
        XCTAssertEqual(log.pending, 0)
    }

    func testAStalledMicrophoneIsCoveredWithSilenceSoTheTurnStillEnds() {
        var watchdog = MicWatchdog()
        watchdog.arm(at: 0)
        XCTAssertNil(watchdog.frame(at: 0.02))
        XCTAssertEqual(watchdog.tick(at: 0.1).silence, 0, "a buffer 80 ms ago is no stall")
        let stall = watchdog.tick(at: 0.4)
        XCTAssertEqual(stall.change, .stalled(afterMs: 380))
        XCTAssertEqual(stall.silence, 0.25, accuracy: 0.0001, "at most a quarter second per tick")
        XCTAssertEqual(watchdog.tick(at: 0.5).silence, 0.23, accuracy: 0.0001, "then only what has not been covered")
        XCTAssertEqual(watchdog.tick(at: 0.6).change, nil, "one stall is reported once")
        XCTAssertEqual(watchdog.frame(at: 0.7), .resumed(stalledMs: 680, silenceSentMs: 580))
        XCTAssertEqual(watchdog.tick(at: 0.8).silence, 0)
        XCTAssertEqual(MicWatchdog.silence(0.1).count, 4_800, "PCM16 at 24 kHz")

        var never = MicWatchdog()
        never.arm(at: 0)
        XCTAssertEqual(never.tick(at: 0.5).change, .stalled(afterMs: 500), "a microphone that never delivered is a stall too")
    }

    // MARK: - Cues

    func testTheCuesAreShortSoftAndTellOnFromOff() {
        let connected = LiveCue.connected.samples()
        let disconnected = LiveCue.disconnected.samples()
        let tick = LiveCue.thinking.samples()
        XCTAssertLessThan(LiveCue.connected.duration, 0.35)
        XCTAssertLessThan(LiveCue.disconnected.duration, 0.35)
        XCTAssertLessThan(LiveCue.thinking.duration, 0.06)
        XCTAssertLessThanOrEqual(connected.map(abs).max()!, 0.25, "well under full scale: a cue, not an alarm")
        XCTAssertLessThanOrEqual(tick.map(abs).max()!, 0.08, "the tick is quieter still: it repeats")
        XCTAssertEqual(tick.first!, 0, accuracy: 0.001, "no click at the start")
        XCTAssertEqual(tick.last!, 0, accuracy: 0.01, "nor at the end")
        XCTAssertNotEqual(connected, disconnected)
        XCTAssertGreaterThan(Self.pitch(Array(connected.suffix(2_000))), Self.pitch(Array(connected.prefix(2_000))), "connected rises")
        XCTAssertLessThan(Self.pitch(Array(disconnected.suffix(2_000))), Self.pitch(Array(disconnected.prefix(2_000))), "disconnected falls")
        XCTAssertEqual(LiveCue.thinking.loop().count, Int(LiveCue.thinking.period * RealtimeAudio.sampleRate))
        XCTAssertEqual(LiveCue.working.loop().count, Int(LiveCue.working.period * RealtimeAudio.sampleRate))
    }

    func testEveryCueStaysQuietAndBrief() {
        for cue in LiveCue.allCases {
            XCTAssertLessThanOrEqual(cue.samples().map(abs).max()!, 0.25, cue.rawValue)
            XCTAssertLessThan(cue.duration, 0.45, cue.rawValue)
        }
        XCTAssertLessThanOrEqual(LiveCue.heard.samples().map(abs).max()!, 0.13, "said every turn, so softer than the one-time notes")
        XCTAssertLessThanOrEqual(LiveCue.working.samples().map(abs).max()!, 0.09, "repeats, so as quiet as the tick")
        XCTAssertLessThan(LiveCue.working.duration / LiveCue.working.period, 0.1, "mostly silence, and the microphone open")
        XCTAssertEqual(LiveCue.working.samples().first!, 0, accuracy: 0.001, "no click")
    }

    func testWorkingCannotPassForThinkingNorFailedForAnythingHappy() {
        XCTAssertGreaterThan(LiveCue.working.period, 2 * LiveCue.thinking.period, "a slower pulse")
        XCTAssertGreaterThan(LiveCue.working.duration, 3 * LiveCue.thinking.duration, "a longer one")
        XCTAssertLessThan(Self.pitch(LiveCue.working.samples()), Self.pitch(LiveCue.thinking.samples()), "and lower")

        let failed = LiveCue.failed.samples()
        XCTAssertLessThan(Self.pitch(Array(failed.suffix(2_000))), Self.pitch(Array(failed.prefix(2_000))), "failed falls")
        for happy in [LiveCue.connected, .heard] {
            XCTAssertLessThan(Self.pitch(failed), Self.pitch(happy.samples()) * 0.7, "well below \(happy.rawValue)")
        }
        XCTAssertLessThan(Self.pitch(failed), Self.pitch(LiveCue.disconnected.samples()) * 0.7, "and below a dropped call")
        XCTAssertLessThan(Self.pitch(LiveCue.ended.samples()), Self.pitch(LiveCue.heard.samples()) * 0.7, "a hang-up is no acknowledgement")
        XCTAssertEqual(Set(LiveCue.allCases.map { $0.samples() }).count, LiveCue.allCases.count, "no two alike")
    }

    /// Zero crossings per sample: enough to tell a higher note from a lower one.
    private static func pitch(_ samples: [Float]) -> Double {
        Double(zip(samples, samples.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count) / Double(samples.count)
    }

    func testTheMicrophoneIsSentAsSilenceOnlyWhileACueSounds() {
        var gate = LiveCueGate()
        gate.oneShot(.connected, at: 10)
        XCTAssertTrue(gate.closes(10.1, length: 0.02))
        XCTAssertFalse(gate.closes(10 + LiveCue.connected.duration + LiveCueGate.tail + 0.01, length: 0.02))

        gate.startLoop(.thinking, at: 20)
        XCTAssertFalse(gate.closes(19.9, length: 0.02), "nothing before the first tick")
        XCTAssertTrue(gate.closes(20.01, length: 0.02))
        XCTAssertFalse(gate.closes(20.5, length: 0.02), "open between ticks: the person can still talk over")
        XCTAssertTrue(gate.closes(20 + LiveCue.thinking.period - 0.01, length: 0.02), "a buffer that runs into the next tick")
        gate.stopLoop()
        XCTAssertFalse(gate.closes(23.01, length: 0.02))

        gate.startLoop(.working, at: 30)
        XCTAssertTrue(gate.closes(30.2, length: 0.02), "the pulse is longer than a tick")
        XCTAssertFalse(gate.closes(31, length: 0.02), "and rarer")
        XCTAssertTrue(gate.closes(32.51, length: 0.02))
    }

    func testACueWaitingItsTurnLeavesTheMicrophoneOpenUntilItSounds() {
        var gate = LiveCueGate()
        gate.oneShot(.failed, at: 12, now: 10)
        XCTAssertFalse(gate.closes(10.5, length: 0.02), "the person can still talk over the end of the reply")
        XCTAssertTrue(gate.closes(12.1, length: 0.02))
        gate.clearOneShots()
        XCTAssertFalse(gate.closes(12.1, length: 0.02), "cancelled: the person talked")

        gate.oneShot(.heard, at: 20)
        gate.oneShot(.failed, at: 20.05, now: 20.02)
        XCTAssertTrue(gate.closes(20.01, length: 0.02), "a second cue does not reopen the first's window")
    }

    func testTheCuesFollowTheCall() {
        var director = LiveCueDirector()
        XCTAssertEqual(director.transition(to: .connecting), [])
        XCTAssertEqual(director.transition(to: .listening), [.play(.connected)], "once, when the call is up")
        XCTAssertEqual(director.transition(to: .thinking), [.startLoop(.thinking)])
        XCTAssertEqual(director.receive(.heardPerson), [.play(.heard, after: LiveCue.heardLead)])
        XCTAssertEqual(director.transition(to: .speaking), [.stopCues], "the instant the reply starts, a heard note still waiting included")
        XCTAssertEqual(director.transition(to: .listening), [], "no second ding")
        XCTAssertEqual(director.transition(to: .thinking), [.startLoop(.thinking)])
        XCTAssertEqual(director.transition(to: .listening), [.stopLoop], "a line not answered")
        _ = director.transition(to: .thinking)
        XCTAssertEqual(director.dropped(), [.stopCues, .play(.disconnected)])
        var never = LiveCueDirector()
        XCTAssertEqual(never.dropped(), [], "a call that never connected makes no sound")
        XCTAssertEqual(never.hungUp(), [], "nor does hanging one up")
    }

    func testAToolSoundsDifferentFromThinkingForAsLongAsItRuns() {
        var director = LiveCueDirector()
        _ = director.transition(to: .listening)
        _ = director.transition(to: .thinking)
        XCTAssertEqual(director.receive(.toolsRunning(1)), [.stopLoop, .startLoop(.working)])
        XCTAssertEqual(director.transition(to: .working), [])
        XCTAssertEqual(director.receive(.toolsRunning(2)), [], "a second tool: the same pulse")
        XCTAssertEqual(director.transition(to: .thinking), [], "a response starting beside a running tool does not turn it into thinking")
        XCTAssertEqual(director.receive(.toolsRunning(1)), [])
        XCTAssertEqual(director.receive(.toolsRunning(0)), [.stopLoop, .startLoop(.thinking)], "back to the tick, which can give up")

        var talkedOver = LiveCueDirector()
        _ = talkedOver.transition(to: .listening)
        XCTAssertEqual(talkedOver.receive(.toolsRunning(1)), [.startLoop(.working)])
        XCTAssertEqual(talkedOver.transition(to: .working), [])
        XCTAssertEqual(talkedOver.receive(.personTalking), [.stopCues], "the instant the person talks")
        XCTAssertEqual(talkedOver.transition(to: .listening), [], "and not back while they do")
        XCTAssertEqual(talkedOver.transition(to: .thinking), [], "not for a response that starts under them either")
        XCTAssertEqual(talkedOver.receive(.personStopped), [.startLoop(.working)], "they stopped, and the tool still runs")
        XCTAssertEqual(talkedOver.transition(to: .speaking), [.stopCues], "the interim answer")
        XCTAssertEqual(talkedOver.transition(to: .listening), [.startLoop(.working)], "which ended, and the tool still runs")
        XCTAssertEqual(talkedOver.receive(.toolsRunning(0)), [.stopLoop])
    }

    func testACueKnowsHowMuchOfTheReplyIsLeftToWaitOut() {
        var playout = LiveReplyPlayout()
        XCTAssertEqual(playout.remaining(at: 10), 0, "nothing queued")
        playout.started(itemID: "r1", at: 10)
        playout.scheduled(samples: Int(2 * RealtimeAudio.sampleRate), at: 10)
        XCTAssertEqual(playout.remaining(at: 10.5), 1.5, accuracy: 0.001)
        XCTAssertEqual(playout.remaining(at: 13), 0, "it played out")
        playout.queueDropped(at: 13)
        XCTAssertEqual(playout.remaining(at: 13), 0, "an engine restart lost what was queued")
    }

    func testNothingSoundsWhileThePersonTalks() {
        var director = LiveCueDirector()
        _ = director.transition(to: .listening)
        _ = director.receive(.personTalking)
        XCTAssertEqual(director.receive(.heardPerson), [], "Zimmer's answer about an earlier line, arriving under the next one")
        XCTAssertEqual(director.receive(.actionFailed), [], "it would close the microphone on them")
        XCTAssertEqual(director.receive(.personStopped), [.play(.failed)], "held, not lost")
    }

    func testATurnsFailureSoundsOnce() {
        var director = LiveCueDirector()
        _ = director.transition(to: .listening)
        XCTAssertEqual(director.receive(.actionFailed), [.play(.failed)])
        XCTAssertEqual(director.receive(.actionFailed), [], "three tools failing is one cue")
        _ = director.receive(.personTalking)
        _ = director.receive(.personStopped)
        XCTAssertEqual(director.receive(.actionFailed), [.play(.failed)], "a new turn")

        var waiting = LiveCueDirector()
        _ = waiting.transition(to: .listening)
        XCTAssertEqual(waiting.receive(.noAnswerComing), [], "a stray error while the call waits for the person")
        _ = waiting.transition(to: .thinking)
        XCTAssertEqual(waiting.receive(.noAnswerComing), [.play(.failed)], "the answer they were waiting for")
    }

    func testAPlainHangUpIsHeardAndIsNotADrop() {
        var director = LiveCueDirector()
        _ = director.transition(to: .listening)
        _ = director.transition(to: .thinking)
        XCTAssertEqual(director.hungUp(), [.stopCues, .play(.ended)], "a heard note still waiting does not get in front of the goodbye")
        XCTAssertEqual(director.hungUp(), [], "the call is over: nothing to say goodbye to")
    }

    func testTheCallSignalsWhatTheCuesHangOn() {
        var conductor = RealtimeConductor()
        let args = event(#"{"type":"response.function_call_arguments.done","call_id":"a","name":"x","arguments":"{}"}"#)
        XCTAssertEqual(conductor.handle(args), [.relay(callID: "a", name: "x", arguments: "{}"), .signal(.toolsRunning(1)), .state(.working)])
        XCTAssertEqual(conductor.relayed(callID: "a", result: LiveToolResult(output: "ok")).filter(Self.isSignal), [.signal(.toolsRunning(0))],
                       "success makes no sound of its own")

        var refused = RealtimeConductor()
        _ = refused.handle(args)
        XCTAssertEqual(refused.relayed(callID: "a", result: LiveToolResult(output: "no", error: true)).filter(Self.isSignal),
                       [.signal(.toolsRunning(0)), .signal(.actionFailed)])
        var unreachable = RealtimeConductor()
        _ = unreachable.handle(args)
        XCTAssertEqual(unreachable.relayed(callID: "a", result: nil, failure: "offline").filter(Self.isSignal),
                       [.signal(.toolsRunning(0)), .signal(.actionFailed)])

        var cut = RealtimeConductor()
        XCTAssertEqual(cut.handle(event(#"{"type":"response.done","response":{"status":"incomplete","output":[]}}"#)),
                       [.state(.listening), .signal(.actionFailed)], "a reply cut short")
        XCTAssertEqual(cut.handle(event(#"{"type":"response.done","response":{"status":"cancelled","output":[]}}"#)),
                       [.state(.listening)], "talked over is no failure")

        var gated = RealtimeConductor(listening: "wake_word")
        XCTAssertEqual(gated.handle(event(#"{"type":"input_audio_buffer.speech_stopped"}"#)), [.signal(.personStopped), .state(.thinking)],
                       "not heard until Zimmer says so")
        XCTAssertEqual(gated.heard(itemID: "u1", respond: true).first, .signal(.heardPerson))
    }

    private static func isSignal(_ effect: RealtimeConductor.Effect) -> Bool {
        if case .signal = effect { return true }
        return false
    }
}
