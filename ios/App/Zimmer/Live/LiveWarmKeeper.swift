import Combine
import Foundation
import Network
import ZimmerKit
import os

/// A connection in standby, taken by a tap: the call's from here.
struct LiveWarmTake {
    enum Connection {
        case realtime(LiveWarmLink)
        case gptLive(GptLiveCall)
    }

    let slot: LiveWarmStart.Slot
    let conversation: Int
    /// What Zimmer said the call runs on when the connection was opened.
    let grant: LiveCallGrant
    let connection: Connection
}

/// Standby, the app's half (`ios/CARPLAY_PREWARM_DESIGN.md`): while the car is connected, or Live is
/// open on the phone on a conversation with voice on, hold a connection ready for **New** and one
/// for **Continue**, so the tap has nothing to wait for but the microphone. What to do and when is
/// `LiveWarmStart`'s (ZimmerKit, tested on Linux), one for each; this does it — reads Zimmer, opens
/// the connection, sees that it is alive, closes it — and hands it to `LiveCall` at the tap.
///
/// There is no flag in the app. What stops it is a hold (`LiveWarmStart.Hold`), the budget, or
/// Zimmer refusing: the Live setting *Standby cap per day* at 0 turns GPT-Live standby off.
///
/// **Nothing a person says goes up a connection in standby.** A Realtime one (`LiveWarmLink`) has no
/// way to send an event. A GPT-Live one (`GptLiveCall` in standby) sends none, and its microphone
/// track is muted from the moment it is made, so the silence the track carries (`LiveStandbySilence`)
/// is the only audio on it. The microphone is not opened, the audio session is not activated, and
/// nothing is shown or played. Only `take`, from the person's tap, hands a connection to a call.
@MainActor
final class LiveWarmKeeper {
    static let shared = LiveWarmKeeper()

    /// Where a tap may come from. The car's name is the one its requests carry.
    enum Place: Hashable { case car, phone }

    private var places: Set<Place> = []
    private lazy var open = LiveWarmHolder(.open, keeper: self)
    private lazy var new = LiveWarmHolder(.new, keeper: self)
    private var holders: [LiveWarmHolder] { [open, new] }
    private let silence = LiveStandbySilence()
    private var ticking: Task<Void, Never>?
    private var monitor: NWPathMonitor?
    private var observers: [NSObjectProtocol] = []
    private var watchers: Set<AnyCancellable> = []
    fileprivate private(set) var online = true
    fileprivate private(set) var constrained = false

    fileprivate static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    fileprivate var active: Bool { !places.isEmpty }
    /// Live open on the phone with no car: only for a conversation the person talks in.
    fileprivate var onPhoneOnly: Bool { !places.contains(.car) }
    fileprivate var surface: ClientSource.Surface { onPhoneOnly ? .ios : .carplay }

    // MARK: - Where the taps are

    /// The CarPlay scene connected.
    func carConnected() {
        places.insert(.car)
        restart()
    }

    /// The scene went. Live may still be open on the phone.
    func carDisconnected() {
        places.remove(.car)
        restart()
    }

    /// Zimmer came to the front on the car's screen: a call may be near.
    func cameToTheFront() {
        guard active else { return }
        perform { $0.interest(at: Self.now) }
    }

    /// Live opened on the phone, or came back to the front there.
    func phoneOpened() {
        // A simulator has no OpenAI to hold a connection to.
        guard !AppEnvironment.shared.isFixture, !places.contains(.phone) else { return }
        places.insert(.phone)
        if places.contains(.car) { cameToTheFront() } else { restart() }
    }

    func phoneClosed() {
        guard places.remove(.phone) != nil, places.isEmpty else { return }
        restart()
    }

    /// The Live settings changed on this phone: what is held was made from the old ones.
    func settingsChanged() {
        guard active else { return }
        perform { $0.settingsChanged(at: Self.now) }
    }

    /// Zimmer has answered a New: it can keep another ready.
    func newWasTaken() {
        guard active else { return }
        new.perform(new.start.taken(at: Self.now))
    }

    private func restart() {
        for holder in holders { holder.stop() }
        ticking?.cancel()
        ticking = nil
        monitor?.cancel()
        monitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        watchers.removeAll()
        silence.stop()
        guard active else { return }
        watch()
        perform { $0.activate(at: Self.now) }
        ticking = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(LiveWarmStart.tickEvery))
                guard let self, !Task.isCancelled else { return }
                self.perform { $0.tick(at: Self.now) }
            }
        }
    }

    // MARK: - The tap

    /// The open conversation, when a connection is held for it and the last read (within
    /// `trustReadFor`) still says it is the open one: Continue calls it without asking Zimmer again.
    func openConversation() -> Int? {
        active ? open.readyConversation : nil
    }

    /// The conversation a connection is held on for New, as it will be once it starts.
    func newConversation() -> LiveConversation? {
        active ? new.readyNew : nil
    }

    /// The person tapped, and the call is starting on `conversation`: the connection held for it, if
    /// there is one that can be trusted. Only this hands one over.
    func take(_ slot: LiveWarmStart.Slot, _ conversation: Int) -> LiveWarmTake? {
        guard active else { return nil }
        let take = (slot == .open ? open : new).take(conversation)
        // The call's own microphone is what the connection carries from here.
        if take != nil { silence.stop() }
        return take
    }

    // MARK: - Internals

    private func perform(_ change: (inout LiveWarmStart) -> [LiveWarmStart.Action]) {
        for holder in holders { holder.perform(change(&holder.start)) }
        connectionsChanged()
    }

    /// A held GPT-Live connection carries silence while no call's engine is feeding the one
    /// microphone there is.
    fileprivate func connectionsChanged() {
        if active, !LiveCall.shared.isActive, holders.contains(where: \.holdsGptLive) { silence.start() } else { silence.stop() }
    }

    /// The call, Low Power Mode, the thermal state and the network, each a reason to decide again.
    private func watch() {
        // Received on the main queue's next turn, as `CarPlayLive` does: by then `isActive` says
        // the same as the state, and a tap has already taken what it is going to.
        LiveCall.shared.$state.map { $0 != .idle }.removeDuplicates().dropFirst().receive(on: DispatchQueue.main).sink { [weak self] active in
            MainActor.assumeIsolated {
                guard let self, self.active else { return }
                // Any call, from standby or not, can change what is open (New ends it): read again after.
                if active { self.open.forgetOverview() }
                self.perform { active ? $0.callStarted(at: Self.now) : $0.callEnded(at: Self.now) }
                // A call is the person talking, whatever the conversation was when it was last read.
                self.reconsider()
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

    /// The phone, or what was read, changed under what is held: decide again.
    fileprivate func reconsider() {
        guard active else { return }
        for holder in holders { holder.reconsider() }
        connectionsChanged()
    }
}

/// One slot's connection and the machine that decides about it.
@MainActor
private final class LiveWarmHolder {
    let slot: LiveWarmStart.Slot
    var start: LiveWarmStart
    private unowned let keeper: LiveWarmKeeper
    private var grant: LiveCallGrant?
    private var connection: LiveWarmTake.Connection?
    private var openedAt: TimeInterval = 0
    private var refreshing: Task<Void, Never>?
    private var refreshAgain = false
    private var minting: Task<Void, Never>?
    /// Continue's: the last read of what is open, and when. The tap uses it instead of asking again.
    private var overview: (value: LiveOverview, at: TimeInterval)?
    private var talked = false
    /// New's: the conversation Zimmer keeps ready.
    private var standby: LiveConversation?
    private var loggedHold: LiveWarmStart.Hold?
    private let log = Logger(subsystem: "com.tadasant.zimmer", category: "live-warm")
    private let telemetry = LiveTelemetry.shared

    private static var now: TimeInterval { LiveWarmKeeper.now }
    private var api: any LiveAPI { AppEnvironment.shared.connection.api.live(from: keeper.surface) }

    init(_ slot: LiveWarmStart.Slot, keeper: LiveWarmKeeper) {
        self.slot = slot
        self.keeper = keeper
        start = LiveWarmStart(slot)
    }

    var holdsGptLive: Bool {
        if case .gptLive = connection { return true }
        return false
    }

    func stop() {
        perform(start.deactivate())
        refreshing?.cancel()
        refreshing = nil
        refreshAgain = false
        minting?.cancel()
        minting = nil
        overview = nil
        talked = false
        standby = nil
        loggedHold = nil
    }

    /// A call began: the conversation it is on is one the person talks in, until read otherwise.
    func forgetOverview() {
        overview = nil
        talked = true
    }

    // MARK: - The tap

    var readyConversation: Int? {
        guard connection != nil, start.phase != .idle, let held = start.conversation, let overview,
              Self.now - overview.at < LiveWarmStart.trustReadFor, overview.value.current == held else { return nil }
        return held
    }

    /// Up, or a GPT-Live one on its way up: a Realtime one that is not up has nothing worth taking.
    var readyNew: LiveConversation? {
        guard connection != nil, start.phase == .warm || (start.phase == .warming && holdsGptLive),
              let standby, standby.id == start.conversation else { return nil }
        return standby
    }

    func take(_ conversation: Int) -> LiveWarmTake? {
        // Not what ICE was saying at the last ping: what it says at the tap.
        if case let .gptLive(call) = connection, start.phase == .warm, !call.isStandingBy {
            failed("the connection was not up at the tap")
        }
        let engine = start.engine
        let claim = start.claim(conversation, at: Self.now)
        telemetry.track(.warmClaim(slot, claim, hold: start.hold, engine: engine))
        // Used once: a retry after this call fails asks Zimmer again, rather than calling a
        // conversation that may have ended since the read.
        overview = nil
        switch claim {
        case .cold: return nil
        case .warm, .warming: break
        }
        standby = nil
        guard let connection, let grant else { return nil }
        self.connection = nil
        self.grant = nil
        minting = nil
        switch connection {
        case let .realtime(link): link.detach()
        case let .gptLive(call): call.detach()
        }
        return LiveWarmTake(slot: slot, conversation: conversation, grant: grant, connection: connection)
    }

    // MARK: - Internals

    func perform(_ actions: [LiveWarmStart.Action]) {
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
            if let hold = start.hold { telemetry.track(.warmHeld(slot, hold)) }
        }
    }

    func reconsider() {
        guard let conditions else { return }
        perform(start.update(conditions, at: Self.now))
    }

    /// Nil before the first read.
    private var conditions: LiveWarmStart.Conditions? {
        let thermal = ProcessInfo.processInfo.thermalState
        var conditions = LiveWarmStart.Conditions(
            callActive: LiveCall.shared.isActive, conversation: nil, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            hot: thermal == .serious || thermal == .critical, constrained: keeper.constrained, online: keeper.online
        )
        switch slot {
        case .open:
            guard let overview = overview?.value else { return nil }
            let current = overview.conversations.first { $0.id == overview.current }
            conditions.conversation = overview.current
            conditions.conversationReady = overview.currentIsReady
            conditions.version = current?.lastActivityAt
            conditions.typing = keeper.onPhoneOnly && current?.mode == .text
        case .new:
            guard let standby else { return nil }
            conditions.conversation = standby.id
            // On the phone, New starts a call only from a conversation with voice on.
            conditions.typing = keeper.onPhoneOnly && !keeper.phoneTalks
        }
        return conditions
    }

    /// The person talks in the open conversation, as Continue's holder last read it.
    var talks: Bool { LiveCall.shared.isActive || talked }

    private func refresh() {
        guard refreshing == nil else {
            // What is on its way may have been answered before whatever this is asked for.
            refreshAgain = true
            return
        }
        let api = api
        let slot = slot
        refreshing = Task { [weak self] in
            var overview: LiveOverview?
            var standby: LiveConversation?
            switch slot {
            case .open: overview = try? await api.liveConversations()
            case .new: standby = try? await api.liveStandby()
            }
            guard let self, !Task.isCancelled else { return }
            self.refreshing = nil
            if self.refreshAgain {
                self.refreshAgain = false
                self.refresh()
                return
            }
            // The one a New has just taken, seen before Zimmer had answered it: not one to be ready on.
            if let found = standby, found.status != .standby || found.id == LiveCall.shared.unansweredNew { standby = nil }
            if let overview {
                self.overview = (overview, Self.now)
                self.talked = overview.conversations.first { $0.id == overview.current }?.mode == .voice
            }
            if let standby { self.standby = standby }
            if overview == nil, standby == nil { self.start.refreshFailed(at: Self.now) }
            // Both: whether New is a call on the phone is the open conversation's mode.
            self.keeper.reconsider()
        }
    }

    private func mint(_ conversation: Int) {
        minting?.cancel()
        let asked = Self.now
        let api = api
        let surface = keeper.surface
        telemetry.track(.warmMinting(slot, conversation: conversation, warms: start.warms))
        minting = Task { [weak self] in
            do {
                let grant = try await api.livePrewarmGrant(conversation)
                guard let self, self.isWarming(conversation) else { return }
                self.grant = grant
                self.start.connecting(grant.isGptLive ? .gptLive : .realtime)
                if let secret = grant.realtime {
                    self.minting = nil
                    self.open(LiveWarmLink(conversation: conversation, secret: secret), asked: asked)
                } else {
                    try await self.openGptLive(conversation, surface: surface, asked: asked)
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.isWarming(conversation) else { return }
                self.minting = nil
                self.failed(Self.describe(error))
            }
        }
    }

    private func isWarming(_ conversation: Int) -> Bool {
        !Task.isCancelled && start.phase == .warming && start.conversation == conversation
    }

    private func open(_ link: LiveWarmLink, asked: TimeInterval) {
        func isHeld(_ link: LiveWarmLink) -> Bool {
            if case let .realtime(held) = connection { return held === link }
            return false
        }
        link.onReady = { [weak self, weak link] in
            guard let self, let link, isHeld(link) else { return }
            self.start.ready(at: Self.now)
            self.telemetry.track(.warmReady(self.slot, engine: .realtime, sinceMint: Self.now - asked))
        }
        link.onHeard = { [weak self, weak link] in
            guard let self, let link, isHeld(link) else { return }
            self.start.heard(at: Self.now)
        }
        link.onFailed = { [weak self, weak link] message in
            guard let self, let link, isHeld(link) else { return }
            self.failed(message)
        }
        connection = .realtime(link)
        openedAt = Self.now
        link.open()
    }

    /// The session, started with inference paused. A tap may take it before it is up: then what
    /// goes wrong with it is the call's to hear, not this holder's.
    private func openGptLive(_ conversation: Int, surface: ClientSource.Surface, asked: TimeInterval) async throws {
        let call = try GptLiveCall(conversation: conversation, surface: surface, muted: true, standby: true) { _ in }
        call.onStandby { [weak self, weak call] signal in
            guard let self, let call, self.holds(call) else { return }
            self.handle(signal, from: call, asked: asked)
        }
        connection = .gptLive(call)
        openedAt = Self.now
        keeper.connectionsChanged()
        do {
            try await call.start()
        } catch {
            call.failedToStart(Self.describe(error))
        }
    }

    private func holds(_ call: GptLiveCall) -> Bool {
        if case let .gptLive(held) = connection { return held === call }
        return false
    }

    private func handle(_ signal: GptLiveCall.Signal, from call: GptLiveCall, asked: TimeInterval) {
        switch signal {
        case .started:
            minting = nil
            start.ready(at: Self.now, life: call.lifeLeft)
            telemetry.track(.warmReady(slot, engine: .gptLive, sinceMint: Self.now - asked, life: call.lifeLeft))
        case .heard:
            start.heard(at: Self.now)
        case .woke:
            failed("GPT-Live woke before a tap")
        case let .dropped(reason):
            failed(reason)
        case let .failure(message):
            failed(message)
        case .state, .firstAudio, .recorded, .delegated, .hangUp, .cue, .inputTiming:
            break
        }
    }

    private func failed(_ message: String) {
        log.error("standby connection failed: \(message, privacy: .public)")
        telemetry.track(.warmFailed(slot, message))
        perform(start.failed(at: Self.now))
        keeper.connectionsChanged()
    }

    private func ping() {
        switch connection {
        case let .realtime(link):
            link.ping { [weak self, weak link] failure in
                guard let self, let link, case let .realtime(held) = self.connection, held === link else { return }
                if let failure {
                    self.failed(failure)
                } else {
                    self.start.heard(at: Self.now)
                }
            }
        case let .gptLive(call):
            // No ping on a data channel: ICE says whether the connection is there. One recovering
            // is left unheard, and is dead if it stays that way.
            if call.isStandingBy { start.heard(at: Self.now) }
        case nil:
            break
        }
    }

    private func close(_ reason: LiveWarmStart.CloseReason) {
        minting?.cancel()
        minting = nil
        grant = nil
        guard let connection else { return }
        self.connection = nil
        telemetry.track(.warmClosed(slot, reason, age: Self.now - openedAt))
        switch connection {
        case let .realtime(link):
            link.close()
        case let .gptLive(call):
            call.detach()
            call.end()
        }
    }

    private static func describe(_ error: Error) -> String {
        if let zimmer = error as? ZimmerError { return zimmer.userMessage }
        return error.localizedDescription
    }
}

extension LiveWarmKeeper {
    /// The open conversation has voice on, as last read: on the phone, New is then a call.
    fileprivate var phoneTalks: Bool { open.talks }
}

/// The silence a GPT-Live connection in standby carries. OpenAI wants the microphone track of one
/// kept active, and a connection with no media at all is one a server may give up on; the microphone
/// itself stays shut until the tap. This makes the silence in memory and hands it to libwebrtc, whose
/// tracks are muted besides. It runs only while no call does: a call's own microphone feeds every
/// connection then, and the muted ones carry silence made from that.
@MainActor
final class LiveStandbySilence {
    private static let every: TimeInterval = 0.1
    private let queue = DispatchQueue(label: "com.tadasant.zimmer.live-standby-silence")
    private var timer: DispatchSourceTimer?

    func start() {
        guard timer == nil else { return }
        LiveWebRTCAudioDevice.shared.audioThreadsChanged()
        let silence = MicWatchdog.silence(Self.every)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.every, repeating: Self.every)
        timer.setEventHandler { @Sendable in LiveWebRTCAudioDevice.shared.deliver(silence) }
        timer.resume()
        self.timer = timer
    }

    /// Stopped, and nothing of it still on its way: the call's engine is next to deliver.
    func stop() {
        guard let timer else { return }
        self.timer = nil
        timer.cancel()
        queue.sync {}
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
