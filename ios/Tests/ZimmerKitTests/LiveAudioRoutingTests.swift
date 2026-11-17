import XCTest
@testable import ZimmerKit

/// What a call's one audio engine carries per voice engine, libwebrtc's audio-device contract,
/// the pull that turns libwebrtc's playout into the engine's floats, and the measurement of
/// whether GPT-Live streams the person's transcript while they speak.
final class LiveAudioRoutingTests: XCTestCase {
    // MARK: - One engine

    func testAGptLiveCallRunsLibwebrtcsMicrophoneAndVoiceOnTheCuesVoiceProcessingEngine() {
        let plan = LiveAudioPlan.gptLive
        XCTAssertEqual(plan.voice, .webRTC, "GPT-Live's voice is pulled onto the engine, not played by libwebrtc's own unit")
        XCTAssertEqual(plan.microphone, .webRTC, "the engine's tap feeds libwebrtc")
        XCTAssertTrue(plan.voiceProcessing, "the engine's input runs Apple's voice processing, as on Realtime")
        XCTAssertFalse(plan.gatesMicrophone, "a cue never silences GPT-Live's microphone: it would cut words")
        XCTAssertEqual(plan.label, "webRTC-mic/webRTC-voice")
    }

    func testARealtimeCallKeepsItsSocketMicrophoneScheduledReplyAndGate() {
        let plan = LiveAudioPlan.realtime
        XCTAssertEqual(plan.voice, .scheduled)
        XCTAssertEqual(plan.microphone, .socket)
        XCTAssertTrue(plan.voiceProcessing)
        XCTAssertTrue(plan.gatesMicrophone)
    }

    // MARK: - libwebrtc's device contract

    func testLibwebrtcsOrderStartsPlayoutAndRecording() {
        var state = LiveAudioDeviceState()
        XCTAssertTrue(state.initialize())
        XCTAssertTrue(state.initializePlayout())
        XCTAssertTrue(state.startPlayout())
        XCTAssertTrue(state.initializeRecording())
        XCTAssertTrue(state.startRecording())
        XCTAssertTrue(state.playing)
        XCTAssertTrue(state.recording)
    }

    func testNothingStartsBeforeItIsInitialized() {
        var state = LiveAudioDeviceState()
        XCTAssertFalse(state.initializePlayout())
        XCTAssertFalse(state.startPlayout())
        XCTAssertFalse(state.initializeRecording())
        XCTAssertFalse(state.startRecording())
        XCTAssertEqual(state, LiveAudioDeviceState())

        XCTAssertTrue(state.initialize())
        XCTAssertFalse(state.startPlayout(), "playout starts only once initialized")
        XCTAssertFalse(state.startRecording(), "recording starts only once initialized")
    }

    func testStoppingNeedsAnotherInitializeAndTerminateClearsEverything() {
        var state = LiveAudioDeviceState()
        _ = state.initialize()
        _ = state.initializePlayout()
        _ = state.startPlayout()
        _ = state.initializeRecording()
        _ = state.startRecording()

        XCTAssertTrue(state.stopPlayout())
        XCTAssertFalse(state.playing)
        XCTAssertTrue(state.recording, "stopping playout leaves the microphone running")
        XCTAssertFalse(state.startPlayout(), "a stopped playout is initialized again first")

        XCTAssertTrue(state.terminate())
        XCTAssertEqual(state, LiveAudioDeviceState())
    }

    // MARK: - Pulling libwebrtc's playout

    func testPlayoutIsPulledAsFloatsInChunks() {
        let frames = LiveVoicePull.chunk + 100
        let output = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let scratch = UnsafeMutablePointer<Int16>.allocate(capacity: LiveVoicePull.chunk)
        defer {
            output.deallocate()
            scratch.deallocate()
        }
        var asked: [Int] = []
        let all = LiveVoicePull.fill(output, frames: frames, scratch: scratch) { samples, count in
            asked.append(count)
            for index in 0..<count { samples[index] = index == 0 ? Int16.max : (index == 1 ? -Int16.max : 0) }
            return true
        }
        XCTAssertTrue(all)
        XCTAssertEqual(asked, [LiveVoicePull.chunk, 100], "never more than the scratch buffer at a time")
        XCTAssertEqual(output[0], 1)
        XCTAssertEqual(output[1], -1)
        XCTAssertEqual(output[2], 0)
        XCTAssertEqual(output[LiveVoicePull.chunk], 1, "the second chunk lands after the first")
        XCTAssertEqual(output[LiveVoicePull.chunk + 1], -1)
    }

    func testAPieceLibwebrtcCouldNotFillIsSilence() {
        let output = UnsafeMutablePointer<Float>.allocate(capacity: 8)
        let scratch = UnsafeMutablePointer<Int16>.allocate(capacity: LiveVoicePull.chunk)
        defer {
            output.deallocate()
            scratch.deallocate()
        }
        output.update(repeating: 0.5, count: 8)
        let all = LiveVoicePull.fill(output, frames: 8, scratch: scratch) { samples, count in
            for index in 0..<count { samples[index] = 1_000 }
            return false
        }
        XCTAssertFalse(all)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: output, count: 8)), Array(repeating: 0, count: 8))
    }

    // MARK: - Does GPT-Live stream the person's transcript?

    private func input(_ text: String, start: Int?, end: Int?) -> JSONValue {
        var fields: [String: JSONValue] = ["type": .string("session.input_transcript.delta"), "delta": .string(text)]
        if let start { fields["start_ms"] = .number(Double(start)) }
        if let end { fields["end_ms"] = .number(Double(end)) }
        return .object(fields)
    }

    private func event(_ type: String) -> JSONValue { .object(["type": .string(type)]) }

    func testFragmentsArrivingAsThePersonSpeaksAreStreamed() {
        var timing = GptLiveInputTiming()
        XCTAssertNil(timing.observe(input("What's ", start: 1_000, end: 1_400), at: 10.5))
        XCTAssertNil(timing.observe(input("running ", start: 1_400, end: 2_200), at: 11.3))
        XCTAssertNil(timing.observe(input("now?", start: 2_200, end: 3_000), at: 12.1))
        let run = timing.observe(event("session.output_transcript.delta"), at: 12.8)
        XCTAssertEqual(run, GptLiveInputTiming.Run(fragments: 3, spokenMs: 2_000, arrivedOverMs: 1_600))
        XCTAssertEqual(run?.streamed, true)
    }

    func testFragmentsArrivingTogetherOnceThePersonStoppedAreNotStreamed() {
        var timing = GptLiveInputTiming()
        _ = timing.observe(input("What's ", start: 1_000, end: 1_400), at: 13.00)
        _ = timing.observe(input("running ", start: 1_400, end: 2_200), at: 13.02)
        _ = timing.observe(input("now?", start: 2_200, end: 3_000), at: 13.05)
        let run = timing.observe(event("session.delegation.created"), at: 13.4)
        XCTAssertEqual(run?.spokenMs, 2_000)
        XCTAssertEqual(run?.arrivedOverMs, 50)
        XCTAssertEqual(run?.streamed, false)
    }

    func testTooLittleToTellSaysNothing() {
        var timing = GptLiveInputTiming()
        _ = timing.observe(input("Yes.", start: 1_000, end: 1_300), at: 1)
        XCTAssertNil(timing.observe(event("session.output_transcript.delta"), at: 2)?.streamed, "one fragment")

        _ = timing.observe(input("No ", start: nil, end: nil), at: 3)
        _ = timing.observe(input("thanks", start: nil, end: nil), at: 4)
        let run = timing.observe(event("session.output_transcript.delta"), at: 5)
        XCTAssertNil(run?.spokenMs, "no intervals")
        XCTAssertNil(run?.streamed)
    }

    func testEachRunIsMeasuredOnceAndOtherEventsEndNothing() {
        var timing = GptLiveInputTiming()
        XCTAssertNil(timing.observe(event("session.output_transcript.delta"), at: 0), "no run yet")
        _ = timing.observe(input("Hi", start: 0, end: 200), at: 1)
        XCTAssertNil(timing.observe(event("session.started"), at: 1.1))
        XCTAssertNil(timing.observe(event("error"), at: 1.2))
        XCTAssertNotNil(timing.observe(event("session.output_transcript.delta"), at: 2))
        XCTAssertNil(timing.observe(event("session.output_transcript.delta"), at: 2.1), "the answer going on is not a new run")
        _ = timing.observe(input("Bye", start: 5_000, end: 5_300), at: 6)
        XCTAssertEqual(timing.finish()?.fragments, 1, "a call ending measures the run under way")
        XCTAssertNil(timing.finish())
    }

    func testSpeakingAgainWithNoAnswerBetweenIsANewRun() {
        var timing = GptLiveInputTiming()
        _ = timing.observe(input("Hello ", start: 0, end: 400), at: 1)
        _ = timing.observe(input("there", start: 400, end: 900), at: 1.5)
        let first = timing.observe(input("Are you there?", start: 6_000, end: 7_000), at: 1.5 + GptLiveInputTiming.runGap + 0.1)
        XCTAssertEqual(first, GptLiveInputTiming.Run(fragments: 2, spokenMs: 900, arrivedOverMs: 500))
        let second = timing.finish()
        XCTAssertEqual(second?.fragments, 1, "the new fragment starts the next run")
        XCTAssertEqual(second?.spokenMs, 1_000)
    }

    func testIntervalsThatAreNotSaneNumbersAreIgnored() {
        var timing = GptLiveInputTiming()
        _ = timing.observe(.object(["type": .string("session.input_transcript.delta"), "start_ms": .number(.nan), "end_ms": .number(1e30)]), at: 1)
        _ = timing.observe(.object(["type": .string("session.input_transcript.delta"), "start_ms": .string("12"), "end_ms": .number(-5)]), at: 2)
        XCTAssertNil(timing.finish()?.spokenMs)
    }

    func testTheRunIsLoggedWithItsVerdict() {
        let run = GptLiveInputTiming.Run(fragments: 3, spokenMs: 2_000, arrivedOverMs: 1_600)
        let event = LiveEvent.gptLiveInputTiming(run)
        XCTAssertEqual(event.name, "gpt_live.input_transcript")
        XCTAssertEqual(event.level, .info)
        let fields = event.fields()
        XCTAssertEqual(fields["streamed"], .bool(true))
        XCTAssertEqual(fields["spoken_ms"], .number(2_000))
        XCTAssertEqual(fields["arrived_over_ms"], .number(1_600))
        XCTAssertEqual(fields["fragments"], .number(3))
    }

    func testTheDeviceSaysWhatLibwebrtcStarted() {
        var state = LiveAudioDeviceState()
        _ = state.initialize()
        _ = state.initializePlayout()
        _ = state.startPlayout()
        let fields = LiveEvent.webRTCAudioDevice("playout_started", state: state).fields()
        XCTAssertEqual(fields["what"], .string("playout_started"))
        XCTAssertEqual(fields["playing"], .bool(true))
        XCTAssertEqual(fields["recording"], .bool(false))
    }
}
