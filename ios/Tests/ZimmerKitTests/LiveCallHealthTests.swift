import XCTest
@testable import ZimmerKit

/// What stops a Live voice call sitting on *Connecting…* or *Listening* for minutes. Each of the
/// bad calls these came from is named on its test.
final class LiveCallHealthTests: XCTestCase {
    private func connected(at time: TimeInterval = 0) -> LiveCallHealth {
        var health = LiveCallHealth()
        health.started(at: time)
        health.connected(at: time)
        return health
    }

    /// Ticks from `from` to `to`, a tenth of a second apart, with what they asked for.
    private func run(_ health: inout LiveCallHealth, from: TimeInterval, to: TimeInterval, stalledSince: TimeInterval? = nil,
                     interrupted: Bool = false, heard: Bool = false, pongs: Bool = false) -> [(at: TimeInterval, action: LiveCallHealth.Action)] {
        var actions: [(TimeInterval, LiveCallHealth.Action)] = []
        var now = from
        while now <= to {
            if heard { health.heard(at: now) }
            for action in health.tick(at: now, stalledSince: stalledSince, interrupted: interrupted) {
                actions.append((now, action))
                if pongs, action == .ping { health.pong(at: now + 0.05) }
            }
            now += 0.1
        }
        return actions
    }

    // MARK: - Connecting

    /// `bda7cf2e`, 771 s on Connecting…, and `a540cb67`, which never left it.
    func testACallThatDoesNotConnectGivesUpAtTheDeadline() {
        var health = LiveCallHealth()
        health.started(at: 100)
        health.stage = .microphone
        XCTAssertEqual(health.tick(at: 114.9, stalledSince: nil, interrupted: false), [])
        XCTAssertEqual(health.tick(at: 115, stalledSince: nil, interrupted: false), [.giveUp(.connectTimedOut(.microphone))])
        XCTAssertEqual(health.tick(at: 116, stalledSince: nil, interrupted: false), [], "once")
        XCTAssertEqual(LiveCallHealth.GiveUp.connectTimedOut(.session).reason, "connect_timed_out")
    }

    func testTheDeadlineStopsMatteringOnceTheCallIsUp() {
        var health = connected()
        XCTAssertFalse(run(&health, from: 0, to: 60, heard: true).contains { $0.action == .giveUp(.connectTimedOut(.secret)) })
    }

    func testNothingHappensBeforeTheCallStarts() {
        var health = LiveCallHealth()
        XCTAssertEqual(health.tick(at: 1_000, stalledSince: nil, interrupted: false), [])
    }

    // MARK: - The socket

    func testACallIsPingedAsSoonAsItIsUpToLearnThatPongsCome() {
        var health = connected(at: 10)
        XCTAssertEqual(health.tick(at: 10.1, stalledSince: nil, interrupted: false), [.ping])
        XCTAssertEqual(health.tick(at: 10.2, stalledSince: nil, interrupted: false), [])
    }

    func testAQuietCallIsPingedAndABusyOneIsNot() {
        var busy = connected()
        XCTAssertEqual(run(&busy, from: 0.1, to: 60, heard: true).map(\.action), [.ping], "only the first")

        var quiet = connected()
        let pings = run(&quiet, from: 0.1, to: 30, pongs: true).filter { $0.action == .ping }.map(\.at)
        XCTAssertEqual(pings.first ?? -1, 0.1, accuracy: 0.01)
        XCTAssertEqual(pings[1], 10.15, accuracy: 0.2, "after ten quiet seconds")
        XCTAssertFalse(run(&quiet, from: 30, to: 60, pongs: true).contains { $0.action == .giveUp(.socketSilent) }, "answered pings keep it alive")
    }

    /// A car driving out of coverage: the socket stays open with nobody on the other end.
    func testASocketThatStopsAnsweringIsDeadAfterTwentySeconds() throws {
        var health = connected()
        _ = health.tick(at: 0.1, stalledSince: nil, interrupted: false)
        health.pong(at: 0.2)
        let gaveUp = try XCTUnwrap(run(&health, from: 0.3, to: 30).first { $0.action == .giveUp(.socketSilent) })
        XCTAssertEqual(gaveUp.at, 20.2, accuracy: 0.11)
    }

    func testAServerThatNeverAnswersPingsCostsTheDetectionNotTheCall() {
        var health = connected()
        XCTAssertFalse(run(&health, from: 0.1, to: 600).contains { $0.action == .giveUp(.socketSilent) })
    }

    /// iOS suspended the app, so the timer slept: that proves nothing about the socket.
    func testATimerThatSleptStartsTheQuietPeriodOver() {
        var health = connected()
        _ = health.tick(at: 0.1, stalledSince: nil, interrupted: false)
        health.pong(at: 0.2)
        XCTAssertEqual(health.tick(at: 60, stalledSince: nil, interrupted: false), [.ping], "a ping, not a death")
        XCTAssertFalse(run(&health, from: 60.1, to: 79).contains { $0.action == .giveUp(.socketSilent) })
    }

    // MARK: - The microphone

    /// `53a10373`: a 55 s interruption that came back. It must not be cut off, and must say so.
    func testAnInterruptionThatComesBackIsReportedAndSurvived() {
        var health = connected()
        let during = run(&health, from: 0.1, to: 55, stalledSince: 0.1, interrupted: true, heard: true).map(\.action)
        XCTAssertEqual(during.filter { $0 == .microphoneLost }.count, 1)
        XCTAssertFalse(during.contains { if case .giveUp = $0 { return true } else { return false } })
        XCTAssertEqual(health.tick(at: 55.1, stalledSince: nil, interrupted: false).first, .microphoneBack)
        XCTAssertEqual(health.tick(at: 55.2, stalledSince: nil, interrupted: false), [])
    }

    /// The interruption has ended and the engine is restarting: `stalledSince` is still set until
    /// the first buffer arrives, and 55 s of it must not read as a microphone dead for 20.
    func testAStallThatOutlivesItsInterruptionIsGivenTheEnginesRestart() {
        var health = connected()
        _ = run(&health, from: 0.1, to: 55, stalledSince: 0.1, interrupted: true, heard: true)
        let restarting = run(&health, from: 55.1, to: 57, stalledSince: 0.1, heard: true).map(\.action)
        XCTAssertFalse(restarting.contains(.giveUp(.microphoneStopped)))
        XCTAssertEqual(health.tick(at: 57.1, stalledSince: nil, interrupted: false).first, .microphoneBack)
    }

    func testAMicrophoneThatNeverComesBackAfterAnInterruptionStillGivesUp() throws {
        var health = connected()
        _ = run(&health, from: 0.1, to: 55, stalledSince: 0.1, interrupted: true, heard: true)
        let gaveUp = try XCTUnwrap(run(&health, from: 55.1, to: 80, stalledSince: 0.1, heard: true).first { $0.action == .giveUp(.microphoneStopped) })
        XCTAssertEqual(gaveUp.at, 75, accuracy: 0.21)
    }

    func testATimerThatSleptThroughAStallDoesNotCountTheSleepAgainstTheMicrophone() throws {
        var health = connected()
        _ = health.tick(at: 0.1, stalledSince: 0.1, interrupted: false)
        XCTAssertFalse(health.tick(at: 60, stalledSince: 0.1, interrupted: false).contains(.giveUp(.microphoneStopped)))
        let gaveUp = try XCTUnwrap(run(&health, from: 60.1, to: 90, stalledSince: 0.1, heard: true).first { $0.action == .giveUp(.microphoneStopped) })
        XCTAssertEqual(gaveUp.at, 80, accuracy: 0.21)
    }

    /// `9c90831a`: the third interruption never ended and the call sat on Listening until the
    /// socket aborted, 117 s later.
    func testAnInterruptionThatNeverEndsGivesUp() throws {
        var health = connected()
        let gaveUp = try XCTUnwrap(run(&health, from: 0.1, to: 120, stalledSince: 0.1, interrupted: true, heard: true)
            .first { $0.action == .giveUp(.microphoneHeld) })
        XCTAssertEqual(gaveUp.at, 90.1, accuracy: 0.11)
    }

    func testAMicrophoneThatStoppedOnItsOwnGivesUpSooner() throws {
        var health = connected()
        let gaveUp = try XCTUnwrap(run(&health, from: 0.1, to: 30, stalledSince: 0.1, heard: true)
            .first { $0.action == .giveUp(.microphoneStopped) })
        XCTAssertEqual(gaveUp.at, 20.1, accuracy: 0.11)
    }

    /// `90fb7c5f`: a 501 ms stall as the car handed the call to the phone.
    func testABlipIsNotWorthMentioning() {
        var health = connected()
        let actions = run(&health, from: 0.1, to: 0.6, stalledSince: 0.1, heard: true).map(\.action)
        XCTAssertFalse(actions.contains(.microphoneLost))
        XCTAssertFalse(health.tick(at: 0.7, stalledSince: nil, interrupted: false).contains(.microphoneBack))
    }

    func testEveryGiveUpHasSomethingToSay() {
        for reason in [LiveCallHealth.GiveUp.connectTimedOut(.secret), .socketSilent, .microphoneStopped, .microphoneHeld] {
            XCTAssertFalse(reason.message.isEmpty)
            XCTAssertFalse(reason.reason.isEmpty)
        }
    }

    func testAGiveUpIsLoggedWithHowFarTheCallGot() throws {
        let telemetry = LiveTelemetry(defaults: nil, autoFlush: false)
        telemetry.track(.callGaveUp(.connectTimedOut(.session), stage: .session, sinceStart: 15))
        telemetry.track(.callGaveUp(.socketSilent, stage: .session, sinceStart: 300))
        let sent = LockedRecords()
        telemetry.setSink { batch in
            sent.add(batch.events)
            return LiveTelemetryAnswer(accepted: batch.events.count, telemetry: nil)
        }
        let done = expectation(description: "sent")
        Task { await telemetry.send(); done.fulfill() }
        wait(for: [done], timeout: 5)
        let records = sent.all
        XCTAssertEqual(records.map(\.name), ["call.gave_up", "call.gave_up"])
        XCTAssertEqual(records[0].fields["stage"], .string("session"))
        XCTAssertNil(records[1].fields["stage"], "only connecting has stages")
    }

    private final class LockedRecords: @unchecked Sendable {
        private let lock = NSLock()
        private var records: [LiveTelemetryRecord] = []
        func add(_ more: [LiveTelemetryRecord]) { lock.withLock { records += more } }
        var all: [LiveTelemetryRecord] { lock.withLock { records } }
    }
}
