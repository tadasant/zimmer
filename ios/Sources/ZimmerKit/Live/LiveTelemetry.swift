import Foundation

/// How much a Live voice call reports, and the order it is reported in: a threshold over four
/// levels. Zimmer's Live setting `voice_telemetry` picks it, each client secret and each batch's
/// answer carries it, and the app keeps the last one it was told for the calls after.
public enum LiveTelemetryLevel: String, Codable, Sendable, CaseIterable, Comparable {
    /// Every step: speech starting and stopping, each response, each cue, each state change.
    /// The shipped default.
    case debug
    /// Milestones: a call starting, connecting and ending, the audio session and route, turn
    /// detection as OpenAI applied it, the timings.
    case info
    /// Something went wrong that the call survived: an interruption, a stalled microphone, a retry.
    case warn
    /// Something the call did not survive, or an error OpenAI or Zimmer sent. Reported at every
    /// level but off.
    case error

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    /// The setting's value as a threshold: nil for `off` (and for nothing this app knows).
    public static func threshold(_ setting: String?) -> LiveTelemetryLevel? {
        setting.flatMap(LiveTelemetryLevel.init(rawValue:))
    }
}

/// One thing that happened in a call. Adding one is a static function on this type, or an ad-hoc
/// `LiveEvent(.debug, "audio.something") { ["key": .int(1)] }`; reporting it is one
/// `telemetry.track(…)`. The fields are built only when the level is kept, so an event below the
/// threshold costs a comparison.
///
/// Never a transcript: names, counts, timings, settings and error messages only.
public struct LiveEvent: Sendable {
    public let level: LiveTelemetryLevel
    public let name: String
    let fields: @Sendable () -> [String: JSONValue]

    public init(_ level: LiveTelemetryLevel, _ name: String, fields: @escaping @Sendable () -> [String: JSONValue] = { [:] }) {
        self.level = level
        self.name = name
        self.fields = fields
    }
}

public extension JSONValue {
    static func int(_ value: Int?) -> JSONValue { value.map { .number(Double($0)) } ?? .null }
    static func ms(_ seconds: TimeInterval?) -> JSONValue { seconds.map { .number(($0 * 1_000).rounded()) } ?? .null }
    static func text(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
}

/// What goes on every batch: which app, on which phone.
public struct LiveTelemetryClient: Codable, Sendable, Equatable {
    public var surface: String
    public var appVersion: String?
    public var appBuild: String?
    public var os: String?
    public var device: String?

    public init(surface: String = "ios", appVersion: String? = nil, appBuild: String? = nil, os: String? = nil, device: String? = nil) {
        self.surface = surface
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.os = os
        self.device = device
    }

    enum CodingKeys: String, CodingKey {
        case surface, os, device
        case appVersion = "app_version"
        case appBuild = "app_build"
    }
}

/// One recorded event, as it is sent (`POST /api/v1/live/telemetry`).
public struct LiveTelemetryRecord: Codable, Sendable, Equatable {
    /// Moves on by one with every event the app records, whatever call it is in, so a trace sorts
    /// by it even when two events share a millisecond.
    public let seq: Int
    public let name: String
    public let level: LiveTelemetryLevel
    /// The phone's wall clock, ISO 8601 with milliseconds.
    public let at: String
    /// Milliseconds since the phone booted: a clock no time-zone or NTP change moves, for durations.
    public let monoMs: Int
    public let callID: String?
    public let conversationID: Int?
    public let fields: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case seq, name, level, at, fields
        case monoMs = "mono_ms"
        case callID = "call_id"
        case conversationID = "conversation_id"
    }
}

public struct LiveTelemetryBatch: Codable, Sendable, Equatable {
    public let client: LiveTelemetryClient
    /// Events the app had to drop since the last batch went through (the buffer was full).
    public let dropped: Int
    public let events: [LiveTelemetryRecord]
}

/// Zimmer's answer to a batch: how many it kept, and the level in force now.
public struct LiveTelemetryAnswer: Decodable, Sendable, Equatable {
    public let accepted: Int
    public let telemetry: String?

    public init(accepted: Int, telemetry: String?) {
        self.accepted = accepted
        self.telemetry = telemetry
    }
}

/// The app's diagnostic log of its Live voice calls, sent to Zimmer in batches, where each event
/// becomes one record on the shipped log stream (`LiveConversations::Telemetry`, readable in
/// VictoriaLogs under `scope.name:="ios.live"`).
///
/// Cheap by construction: `track` checks the level, then takes a lock to append one small value;
/// it never does I/O. Sending is a detached task, never on the caller's thread: within 15 seconds
/// of an event, at once when 40 are waiting, and on `flush()` (a call ending, the app going to
/// the background); a flush during a send is sent right after it. The buffer holds at most 500,
/// in memory only; past that the oldest are dropped and counted, and the count rides on the
/// next batch. A batch that fails to send goes back in the buffer for the next try. What is
/// waiting when the app is terminated is lost.
public final class LiveTelemetry: @unchecked Sendable {
    public typealias Sink = @Sendable (LiveTelemetryBatch) async throws -> LiveTelemetryAnswer

    public static let capacity = 500
    public static let batchSize = 40
    public static let flushEvery: Duration = .seconds(15)
    static let thresholdKey = "live.telemetry.threshold"

    private let lock = NSLock()
    private var buffer: [LiveTelemetryRecord] = []
    private var dropped = 0
    private var seq = 0
    private var sending = false
    /// A flush came while a batch was out: send again as soon as it is answered.
    private var again = false
    private var timer: Task<Void, Never>?
    private var minimum: LiveTelemetryLevel?
    private var call: (id: String, conversation: Int?)?
    private var client: LiveTelemetryClient
    private var sink: Sink?
    private let defaults: UserDefaults?
    private let now: @Sendable () -> Date
    private let uptime: @Sendable () -> TimeInterval
    private let autoFlush: Bool

    /// `defaults`: where the last level Zimmer gave is kept across launches; with none, or none
    /// stored, the level is `debug`, the shipped default.
    public init(client: LiveTelemetryClient = LiveTelemetryClient(), defaults: UserDefaults? = .standard,
                now: @escaping @Sendable () -> Date = Date.init,
                uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                autoFlush: Bool = true, sink: Sink? = nil) {
        self.client = client
        self.defaults = defaults
        self.now = now
        self.uptime = uptime
        self.autoFlush = autoFlush
        self.sink = sink
        let stored = defaults?.string(forKey: Self.thresholdKey)
        minimum = stored.map { LiveTelemetryLevel.threshold($0) } ?? .debug
    }

    /// Where batches go. Events tracked before there is one wait in the buffer.
    public func setSink(_ sink: Sink?) {
        lock.withLock { self.sink = sink }
    }

    /// The level in force; nil is off.
    public var threshold: LiveTelemetryLevel? { lock.withLock { minimum } }

    /// The level Zimmer gave (a client secret's `telemetry`, a batch's answer). Kept for the next
    /// launch. Off empties the buffer.
    public func adopt(_ setting: String?) {
        guard let setting else { return }
        let level = LiveTelemetryLevel.threshold(setting)
        lock.withLock {
            minimum = level
            if level == nil {
                buffer.removeAll()
            } else if let level {
                buffer.removeAll { $0.level < level }
            }
        }
        defaults?.set(setting, forKey: Self.thresholdKey)
    }

    public func updateClient(_ change: (inout LiveTelemetryClient) -> Void) {
        lock.withLock { change(&client) }
    }

    /// A call starts: every event until `endCall()` carries its id. Returns the id.
    @discardableResult
    public func beginCall(conversation: Int?) -> String {
        let id = UUID().uuidString.lowercased()
        lock.withLock { call = (id, conversation) }
        return id
    }

    public func endCall() {
        lock.withLock { call = nil }
    }

    public var callID: String? { lock.withLock { call?.id } }

    public func track(_ event: LiveEvent) {
        guard let minimum = threshold, event.level >= minimum else { return }
        let fields = event.fields().filter { $0.value != .null }
        let wall = now()
        let mono = Int((uptime() * 1_000).rounded())
        let full: Bool = lock.withLock {
            seq += 1
            buffer.append(LiveTelemetryRecord(seq: seq, name: event.name, level: event.level, at: Self.iso(wall), monoMs: mono,
                                              callID: call?.id, conversationID: call?.conversation, fields: fields))
            if buffer.count > Self.capacity {
                let over = buffer.count - Self.capacity
                buffer.removeFirst(over)
                dropped += over
            }
            return buffer.count >= Self.batchSize
        }
        guard autoFlush else { return }
        if full { flush() } else { armTimer() }
    }

    /// Send what is waiting, off the caller's thread.
    public func flush() {
        Task.detached { [self] in await send() }
    }

    /// Send what is waiting and return when it has been answered (or failed).
    public func send() async {
        guard let (batch, sink) = takeBatch() else { return }
        do {
            let answer = try await sink(batch)
            let followUp = lock.withLock {
                sending = false
                defer { again = false }
                return again || buffer.count >= Self.batchSize
            }
            adopt(answer.telemetry)
            // A flush, or a batch's worth, came in while this one was out.
            if followUp { await send() }
        } catch {
            lock.withLock {
                sending = false
                buffer.insert(contentsOf: batch.events, at: 0)
                dropped += batch.dropped
                if buffer.count > Self.capacity {
                    let over = buffer.count - Self.capacity
                    buffer.removeFirst(over)
                    dropped += over
                }
            }
            armTimer()
        }
    }

    /// Events waiting to be sent.
    public var pending: Int { lock.withLock { buffer.count } }

    // MARK: - Internals

    private func takeBatch() -> (LiveTelemetryBatch, Sink)? {
        lock.withLock {
            if sending { again = true }
            guard !sending, !buffer.isEmpty, let sink else { return nil }
            sending = true
            let events = Array(buffer.prefix(100))
            buffer.removeFirst(events.count)
            let batch = LiveTelemetryBatch(client: client, dropped: dropped, events: events)
            dropped = 0
            return (batch, sink)
        }
    }

    private func armTimer() {
        guard autoFlush else { return }
        lock.withLock {
            guard timer == nil else { return }
            timer = Task.detached { [weak self] in
                try? await Task.sleep(for: Self.flushEvery)
                guard let self else { return }
                self.lock.withLock { self.timer = nil }
                await self.send()
            }
        }
    }

    /// ISO8601DateFormatter is thread-safe; one is made, not one per event.
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func iso(_ date: Date) -> String { formatter.string(from: date) }
}
