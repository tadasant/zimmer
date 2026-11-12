import Combine
import Foundation
import Network
import ZimmerKit
import os

/// CarPlay pre-warm, the app's half: while the car is connected and no call is up, keep one
/// Realtime connection ready for Continue (`ios/CARPLAY_PREWARM_DESIGN.md`). What to do and when
/// is `LiveWarmStart`'s (ZimmerKit, tested on Linux); this does it — reads Zimmer, mints, opens
/// and pings the socket, closes it — and hands the connection to `LiveCall` when the driver taps.
///
/// On for every car connection. There is no flag: what stops it is a hold (`LiveWarmStart.Hold`)
/// — a call up, Low Power Mode, heat, Low Data Mode, no network, nothing open — or the per-drive
/// budget.
///
/// **Nothing goes up a warm connection.** `LiveWarmLink` has no way to send an event: it opens the
/// socket, reads what OpenAI says, and pings. The microphone is not touched, the audio session is
/// not activated, and nothing is shown or played. Only `claim`, from the driver's tap, hands the
/// connection to the call, and only the call sends on it.
@MainActor
final class LiveWarmKeeper {
    static let shared = LiveWarmKeeper()

    private var start = LiveWarmStart()
    private var link: LiveWarmLink?
    private var connected = false
    private var ticking: Task<Void, Never>?
    private var refreshing: Task<Void, Never>?
    private var minting: Task<Void, Never>?
    /// The last read of what is open, and when: Continue's tap uses it instead of asking again.
    private var overview: (value: LiveOverview, at: TimeInterval)?
    private var loggedHold: LiveWarmStart.Hold?
    private var online = true
    private var constrained = false
    private var monitor: NWPathMonitor?
    private var observers: [NSObjectProtocol] = []
    private var watchers: Set<AnyCancellable> = []
    private let log = Logger(subsystem: "com.tadasant.zimmer", category: "live-warm")
    private let telemetry = LiveTelemetry.shared

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private var api: any LiveAPI { AppEnvironment.shared.connection.api.live(from: .carplay) }

    // MARK: - The car

    /// The CarPlay scene connected: read what is open, and warm it.
    func carConnected() {
        carDisconnected()
        connected = true
        watch()
        perform(start.carConnected(at: Self.now))
        ticking = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(LiveWarmStart.tickEvery))
                guard let self, !Task.isCancelled else { return }
                self.perform(self.start.tick(at: Self.now))
            }
        }
    }

    /// The scene went: close everything, and stop watching.
    func carDisconnected() {
        perform(start.carDisconnected())
        connected = false
        ticking?.cancel()
        ticking = nil
        refreshing?.cancel()
        refreshing = nil
        minting?.cancel()
        minting = nil
        overview = nil
        loggedHold = nil
        monitor?.cancel()
        monitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        watchers.removeAll()
    }

    // MARK: - The tap

    /// The open conversation, as read within the last `refreshEvery`: Continue
    /// calls it without asking Zimmer again. Nil sends the tap the old way.
    func freshCurrent() -> Int? {
        guard connected, let overview, Self.now - overview.at < LiveWarmStart.refreshEvery else { return nil }
        return overview.value.current
    }

    /// The driver tapped, and the call is starting on `conversation`: the warm connection, if
    /// there is one for it that can be trusted. Only this hands one over.
    func claim(_ conversation: Int) -> LiveWarmLink? {
        guard connected else { return nil }
        let claim = start.claim(conversation, at: Self.now)
        telemetry.track(.warmClaim(claim, hold: start.hold))
        // Used once: a retry after this call fails asks Zimmer what is open again, rather than
        // calling a conversation that may have ended since the read.
        overview = nil
        guard case .warm = claim, let link else { return nil }
        self.link = nil
        link.detach()
        return link
    }

    // MARK: - Internals

    private func perform(_ actions: [LiveWarmStart.Action]) {
        for action in actions {
            switch action {
            case .refresh: refresh()
            case let .mint(conversation): mint(conversation)
            case .ping: ping()
            case let .close(reason): close(reason)
            }
        }
        if start.hold != loggedHold {
            loggedHold = start.hold
            if let hold = start.hold { telemetry.track(.warmHeld(hold)) }
        }
    }

    private func conditions(_ overview: LiveOverview) -> LiveWarmStart.Conditions {
        let thermal = ProcessInfo.processInfo.thermalState
        return LiveWarmStart.Conditions(
            callActive: LiveCall.shared.isActive, conversation: overview.current,
            conversationReady: overview.currentIsReady, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            hot: thermal == .serious || thermal == .critical, constrained: constrained, online: online
        )
    }

    /// The phone changed under a warm connection: decide again on the last read.
    private func reconsider() {
        guard connected, let overview else { return }
        perform(start.update(conditions(overview.value), at: Self.now))
    }

    private func refresh() {
        guard refreshing == nil else { return }
        let api = api
        refreshing = Task { [weak self] in
            let read = try? await api.liveConversations()
            guard let self, !Task.isCancelled else { return }
            self.refreshing = nil
            guard let read else { return }
            self.overview = (read, Self.now)
            self.perform(self.start.update(self.conditions(read), at: Self.now))
        }
    }

    private func mint(_ conversation: Int) {
        minting?.cancel()
        let asked = Self.now
        let api = api
        telemetry.track(.warmMinting(conversation: conversation, warms: start.warms))
        minting = Task { [weak self] in
            do {
                let secret = try await api.livePrewarmSecret(conversation)
                guard let self, !Task.isCancelled, self.start.phase == .warming, self.start.conversation == conversation else { return }
                self.minting = nil
                self.open(LiveWarmLink(conversation: conversation, secret: secret), asked: asked)
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled, self.start.phase == .warming, self.start.conversation == conversation else { return }
                self.minting = nil
                self.failed(Self.describe(error))
            }
        }
    }

    private func open(_ link: LiveWarmLink, asked: TimeInterval) {
        link.onReady = { [weak self, weak link] in
            guard let self, let link, self.link === link else { return }
            self.start.ready(at: Self.now)
            self.telemetry.track(.warmReady(sinceMint: Self.now - asked))
        }
        link.onHeard = { [weak self, weak link] in
            guard let self, let link, self.link === link else { return }
            self.start.heard(at: Self.now)
        }
        link.onFailed = { [weak self, weak link] message in
            guard let self, let link, self.link === link else { return }
            self.failed(message)
        }
        self.link = link
        link.open()
    }

    private func failed(_ message: String) {
        log.error("warm connection failed: \(message, privacy: .public)")
        telemetry.track(.warmFailed(message))
        perform(start.failed(at: Self.now))
    }

    private func ping() {
        guard let link else { return }
        link.ping { [weak self, weak link] failure in
            guard let self, let link, self.link === link else { return }
            if let failure {
                self.failed(failure)
            } else {
                self.start.heard(at: Self.now)
            }
        }
    }

    private func close(_ reason: LiveWarmStart.CloseReason) {
        minting?.cancel()
        minting = nil
        guard let link else { return }
        self.link = nil
        telemetry.track(.warmClosed(reason, age: Self.now - link.openedAt))
        link.close()
    }

    /// The call, Low Power Mode, the thermal state and the network, each a reason to decide again.
    private func watch() {
        // Received on the main queue's next turn, as `CarPlayLive` does: by then `isActive` says
        // the same as the state, and a tap has already claimed what it is going to.
        LiveCall.shared.$state.map { $0 != .idle }.removeDuplicates().dropFirst().receive(on: DispatchQueue.main).sink { [weak self] active in
            MainActor.assumeIsolated {
                guard let self, self.connected else { return }
                self.perform(active ? self.start.callStarted(at: Self.now) : self.start.callEnded(at: Self.now))
            }
        }.store(in: &watchers)
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconsider() }
            })
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let constrained = path.isConstrained
            Task { @MainActor in
                guard let self, self.online != online || self.constrained != constrained else { return }
                self.online = online
                self.constrained = constrained
                self.reconsider()
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.tadasant.zimmer.live-warm.path"))
        self.monitor = monitor
    }

    private static func describe(_ error: Error) -> String {
        if let zimmer = error as? ZimmerError { return zimmer.userMessage }
        return error.localizedDescription
    }
}

/// One warm Realtime connection: a WebSocket opened with a prewarm secret, and what OpenAI has said
/// on it. It can open, read, ping and close. **It cannot send an event**: there is no method for
/// it, so nothing reaches OpenAI from here but the handshake and WebSocket pings.
///
/// The tap hands it to `LiveCall` (`handOver`), which reads what OpenAI already said, in order,
/// and everything after; from then on the call owns the socket and is the only thing that sends.
@MainActor
final class LiveWarmLink {
    let conversation: Int
    let secret: LiveClientSecret
    let task: URLSessionWebSocketTask
    let openedAt = ProcessInfo.processInfo.systemUptime

    var onReady: (@MainActor () -> Void)?
    var onHeard: (@MainActor () -> Void)?
    var onFailed: (@MainActor (String) -> Void)?

    /// What OpenAI said before the tap, for the call to read first.
    private var held: [String] = []
    private var receiver: (@MainActor (String?, String?) -> Void)?
    private var closed = false

    init(conversation: Int, secret: LiveClientSecret) {
        self.conversation = conversation
        self.secret = secret
        var request = URLRequest(url: secret.websocketURL)
        request.setValue("Bearer \(secret.clientSecret)", forHTTPHeaderField: "Authorization")
        task = URLSession.shared.webSocketTask(with: request)
    }

    func open() {
        task.resume()
        receiveNext()
    }

    /// A WebSocket ping: a control frame, not a Realtime event. `done` gets the failure, or nil.
    func ping(_ done: @escaping @MainActor @Sendable (String?) -> Void) {
        task.sendPing { error in
            let failure = error?.localizedDescription
            Task { @MainActor in done(failure) }
        }
    }

    /// The keeper lets go: nothing more is reported to it.
    func detach() {
        onReady = nil
        onHeard = nil
        onFailed = nil
    }

    /// The call takes the connection: `receiver` gets what OpenAI already said, in order, then
    /// everything after it — the text of an event, or the failure that closed the socket.
    func handOver(to receiver: @escaping @MainActor (String?, String?) -> Void) {
        detach()
        self.receiver = receiver
        let earlier = held
        held = []
        for text in earlier { receiver(text, nil) }
    }

    /// Close it, and hear nothing more from it: a socket closed on purpose is not a failure.
    func close() {
        closed = true
        receiver = nil
        detach()
        task.cancel(with: .normalClosure, reason: nil)
    }

    private func receiveNext() {
        task.receive { [weak self] result in
            let text: String? = switch result {
            case let .success(.string(string)): string
            case let .success(.data(data)): String(data: data, encoding: .utf8)
            default: nil
            }
            let failure: String? = if case let .failure(error) = result { error.localizedDescription } else { nil }
            Task { @MainActor in self?.received(text: text, failure: failure) }
        }
    }

    private func received(text: String?, failure: String?) {
        guard !closed else { return }
        if let receiver {
            receiver(text, failure)
            if failure == nil { receiveNext() }
            return
        }
        if let failure {
            closed = true
            onFailed?(failure)
            return
        }
        if let text {
            held.append(text)
            onHeard?()
            if JSONValue.parse(text)?["type"]?.string == "session.created" { onReady?() }
        }
        receiveNext()
    }
}
