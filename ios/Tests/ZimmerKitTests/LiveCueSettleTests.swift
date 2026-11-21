import XCTest
@testable import ZimmerKit

/// The cues wait for the person's turn to really end. Turn detection ends a turn on a pause of
/// half a second or less — OpenAI's `speech_stopped` on the Realtime engine, the transcript going
/// quiet on GPT-Live — and a *heard* note or a *thinking* pulse there tells a driver mid-thought
/// that they were cut off. So whatever answers a stop waits out `LiveCue.settle`, and the person
/// talking again cancels it before it sounds. The web twin is `live_cues_settle_test.rb`.
final class LiveCueSettleTests: XCTestCase {
    /// What a call's audio engine does with the director's actions, as a timeline: a one-shot
    /// sounds at `after`, a loop at `after + lead` and every `period` from there, and `stopCues` /
    /// `stopLoop` drop whatever has not sounded. `sounded` is what the person actually heard.
    private struct Speaker {
        var now: TimeInterval = 0
        var director = LiveCueDirector()
        private var pending: [(cue: LiveCue, at: TimeInterval)] = []
        private var loop: (cue: LiveCue, next: TimeInterval)?
        private(set) var sounded: [LiveCue] = []

        mutating func perform(_ actions: [LiveCueDirector.Action]) {
            for action in actions {
                switch action {
                case let .play(cue, delay): pending.append((cue, now + delay))
                case let .startLoop(cue, delay): loop = (cue, now + delay + cue.lead)
                case .stopLoop: loop = nil
                case .stopCues:
                    loop = nil
                    pending = []
                }
            }
        }

        mutating func wait(_ seconds: TimeInterval) {
            let until = now + seconds
            for shot in pending.filter({ $0.at <= until }).sorted(by: { $0.at < $1.at }) { sounded.append(shot.cue) }
            pending.removeAll { $0.at <= until }
            while let current = loop, current.next <= until {
                sounded.append(current.cue)
                loop = (current.cue, current.next + current.cue.period)
            }
            now = until
        }

        mutating func state(_ state: LiveVoiceState) { perform(director.transition(to: state)) }
        mutating func signal(_ signal: LiveCueDirector.Signal) { perform(director.receive(signal)) }

        /// The Realtime engine at `speech_stopped` (`RealtimeConductor`), and GPT-Live once the
        /// person's transcript goes quiet (`GptLiveConductor`): the same three, in this order.
        mutating func stopped() {
            signal(.personStopped)
            state(.thinking)
            signal(.heardPerson)
        }

        mutating func talking() {
            signal(.personTalking)
            state(.listening)
        }
    }

    /// A call up and heard connecting, then the person talking.
    private func call() -> Speaker {
        var speaker = Speaker()
        speaker.state(.listening)
        speaker.wait(1)
        XCTAssertEqual(speaker.sounded, [.connected])
        speaker.talking()
        speaker.wait(2)
        return speaker
    }

    func testAShortPauseFollowedByMoreSpeechSoundsNothing() {
        var speaker = call()
        speaker.stopped()
        speaker.wait(0.5)
        speaker.talking()
        speaker.wait(5)
        XCTAssertEqual(speaker.sounded, [.connected], "the pause they talked on from was silent")
    }

    func testAPauseJustShortOfSettleIsStillAPause() {
        var speaker = call()
        speaker.stopped()
        speaker.wait(LiveCue.settle - 0.05)
        speaker.talking()
        speaker.wait(5)
        XCTAssertEqual(speaker.sounded, [.connected])
    }

    func testSeveralPausesInOneLongThoughtSoundNothing() {
        var speaker = call()
        for _ in 0..<4 {
            speaker.stopped()
            speaker.wait(0.7)
            speaker.talking()
            speaker.wait(1.5)
        }
        XCTAssertEqual(speaker.sounded, [.connected])
    }

    func testARealEndOfTurnSoundsHeardThenThinking() {
        var speaker = call()
        speaker.stopped()
        speaker.wait(LiveCue.settle - 0.05)
        XCTAssertEqual(speaker.sounded, [.connected], "not before the settle time")
        speaker.wait(0.1)
        XCTAssertEqual(speaker.sounded, [.connected, .heard], "heard once they have been quiet for it")
        speaker.wait(LiveCue.thinking.lead)
        XCTAssertEqual(speaker.sounded, [.connected, .heard, .thinking], "then the thinking pulse")
    }

    func testAnAnswerWithinTheSettleTimeGetsNoCue() {
        var speaker = call()
        speaker.stopped()
        speaker.wait(0.9)
        speaker.state(.speaking)
        speaker.wait(5)
        XCTAssertEqual(speaker.sounded, [.connected], "the reply is the cue")
    }

    func testAPauseWhileAToolRunsBringsTheWorkingLoopBackOnlyAfterSettle() {
        var speaker = call()
        // GPT-Live delegating the line: the person stopped, and a tool started at once.
        speaker.signal(.personStopped)
        speaker.signal(.toolsRunning(1))
        speaker.state(.working)
        speaker.wait(0.5)
        XCTAssertEqual(speaker.sounded, [.connected, .working], "a tool starting is committed work and does not wait")
        speaker.talking()
        speaker.wait(1)
        speaker.signal(.personStopped)
        speaker.wait(0.6)
        speaker.talking()
        speaker.wait(3)
        XCTAssertEqual(speaker.sounded, [.connected, .working], "the pause they talked on from was silent")
        speaker.signal(.personStopped)
        speaker.wait(LiveCue.settle + LiveCue.working.lead + 0.05)
        XCTAssertEqual(speaker.sounded, [.connected, .working, .working], "a real stop brings it back")
    }

    func testADelegationRightAfterTheStopDoesNotWait() {
        var speaker = call()
        speaker.signal(.personStopped)
        speaker.signal(.toolsRunning(1))
        speaker.state(.working)
        speaker.wait(LiveCue.working.lead + 0.05)
        XCTAssertEqual(speaker.sounded, [.connected, .working])
    }

    func testAFailureHeldWhileThePersonTalksWaitsOutSettle() {
        var paused = call()
        paused.signal(.actionFailed)
        paused.signal(.personStopped)
        paused.wait(0.5)
        paused.talking()
        paused.wait(3)
        XCTAssertEqual(paused.sounded, [.connected], "not on a pause")

        var done = call()
        done.signal(.actionFailed)
        done.signal(.personStopped)
        done.wait(LiveCue.settle - 0.05)
        XCTAssertEqual(done.sounded, [.connected])
        done.wait(0.1)
        XCTAssertEqual(done.sounded, [.connected, .failed])
    }

    func testOnlyALoopThatAnswersAStopWaits() {
        var director = LiveCueDirector()
        _ = director.transition(to: .listening)
        XCTAssertEqual(director.transition(to: .thinking), [.startLoop(.thinking)], "a response the person did not just stop for")
        _ = director.receive(.personTalking)
        _ = director.transition(to: .listening)
        XCTAssertEqual(director.receive(.personStopped), [])
        XCTAssertEqual(director.transition(to: .thinking), [.startLoop(.thinking, after: LiveCue.settle)])
        XCTAssertEqual(director.receive(.heardPerson), [.play(.heard, after: LiveCue.settle)])
        XCTAssertEqual(director.receive(.toolsRunning(1)), [.stopLoop, .startLoop(.working)], "the stop is answered: no second wait")

        // Gated, speech under a reply does not cut it off: its stop is not a turn the call is answering.
        var gated = LiveCueDirector()
        _ = gated.transition(to: .listening)
        _ = gated.transition(to: .speaking)
        _ = gated.receive(.personTalking)
        XCTAssertEqual(gated.receive(.personStopped), [])
        XCTAssertEqual(gated.transition(to: .thinking), [.startLoop(.thinking)], "the next response's loop does not wait for it")
    }

    /// The GPT-Live conductor's own end of a line, through the director.
    func testGptLiveALineGoneQuietWaitsOutSettle() {
        var conductor = GptLiveConductor(callKey: "k")
        var speaker = Speaker()
        func apply(_ effects: [GptLiveConductor.Effect]) {
            for effect in effects {
                switch effect {
                case let .state(state): speaker.state(state)
                case let .signal(signal): speaker.signal(signal)
                default: break
                }
            }
        }
        func input(_ text: String) -> JSONValue {
            .object(["type": .string("session.input_transcript.delta"), "delta": .string(text)])
        }
        apply(conductor.handle(.object(["type": .string("session.started")]), at: 0))
        speaker.wait(1)
        apply(conductor.handle(input("Start a "), at: 1))
        speaker.wait(1)
        // The transcript goes quiet past heardIdle: GPT-Live counts the line heard.
        apply(conductor.tick(at: 1 + GptLiveConductor.heardIdle))
        speaker.wait(1)
        apply(conductor.handle(input("session for the docs"), at: 2.6))
        speaker.wait(4)
        XCTAssertEqual(speaker.sounded, [.connected], "the pause they talked on from was silent")
        apply(conductor.tick(at: 2.6 + GptLiveConductor.heardIdle))
        speaker.wait(LiveCue.settle + 0.05)
        XCTAssertEqual(speaker.sounded, [.connected, .heard])
    }
}
