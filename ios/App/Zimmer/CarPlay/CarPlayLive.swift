import CarPlay
import Combine
import Foundation
import ZimmerKit
import os

/// Live Mode in the car: the call screen, and the one way to talk to Zimmer.
///
/// The call is `LiveCall.shared`, the same one the phone's Live screen drives, so a call started
/// at the desk carries on in the car and the other way round. Starting from the car resumes the
/// open conversation with voice on, or starts a new one with voice on: one button, no choice to
/// make while driving. Tapping a session's row starts the same call with an opening line that
/// names the session, so the model answers about that session first. There is one
/// conversation; the rows are ways into it.
///
/// A call started here, or taken over from the phone, says it is `carplay` on every request,
/// so Zimmer tells the live model the person is in a car. When the car disconnects with the
/// call still up, the call carries on as the phone's again.
///
/// **When the call cannot connect, or drops, the car says so on the Talk tile and tries again,
/// quietly** (`LiveRetry`): *Live Mode unavailable, retrying…*, then *Tap to retry* once the
/// retries are spent. It never speaks with another voice: the Realtime call is the car's only
/// voice.
///
/// While the call runs the screen is a voice control template, as Apple requires of a
/// voice-based conversational app while it records. It carries what the template can carry:
///
/// - the call's state as its picture and title — connecting, listening, thinking, speaking,
///   working — one state each, the five CarPlay keeps (`LiveCallScreen`), with Muted said in
///   the title;
/// - the session the conversation is about, in the title's long variant: the one the
///   conversation touched last through a tool call, read from Zimmer
///   (`GET /live_conversations/:id/sessions`) every time the call relays one;
/// - what the call is doing right now, while it is working, as a trailing bar button used as a
///   label ("Starting work…", "Checking on a session…"), because a bar button is the one text on
///   this template that can change in place;
/// - Mute and Hang up as the two action buttons iOS 26.4 allows.
///
/// A voice control state's title is fixed when the state is made, so a new subject, or muting,
/// rebuilds the template and presents it in place of the old one. A new subject waits a
/// moment, so a burst of tool calls is one blink; muting rebuilds at once.
///
/// Every modal change goes through `CarPlayNavigator`, one at a time: CarPlay refuses a change
/// made mid-animation, and a refused change with no completion is a crash.
@MainActor
final class CarPlayLive {
    /// The call ended: the board should read again.
    var onEnd: (() -> Void)?
    /// The call's state, or the retry's, changed: the Talk tile should say so.
    var onChange: (() -> Void)?

    private let call = LiveCall.shared
    private var navigator: CarPlayNavigator<CPInterfaceController>?
    private var template: CPVoiceControlTemplate?
    /// The context the template on screen was built from.
    private var drawn: LiveContext?
    private var context = LiveContext()
    private var watchers: Set<AnyCancellable> = []
    private var contextRead: Task<Void, Never>?
    private var rebuild: Task<Void, Never>?
    /// The server has no `GET /live_conversations/:id/sessions` (404): asked once per call.
    private var subjectRouteMissing = false
    private(set) var retry = LiveRetry()
    private var retryWait: Task<Void, Never>?
    /// The opening line of the call the driver asked for, until the call is up to hear it.
    private var opening: String?
    private let log = Logger(subsystem: "com.tadasant.zimmer", category: "carplay-live")

    /// How many sessions need the driver, for the title when the call has no subject yet.
    var needsYou = 0 {
        didSet {
            context.needsYou = needsYou
            scheduleRebuild()
        }
    }

    init(interfaceController: CPInterfaceController) {
        let navigator = CarPlayNavigator(host: interfaceController)
        navigator.onError = { [log] message in log.error("\(message, privacy: .public)") }
        self.navigator = navigator
        // A `@Published` property publishes in its `willSet`, before the value is stored, so a
        // sink that reads the call (`isActive`, `state`, `lastError`) would read the state it
        // is leaving. Each sink is received on the main queue's next turn instead, when every
        // property says the same thing: the screen activates the state the call is in, and the
        // tile counts a call that just ended as ended. LiveCall is main-actor and publishes
        // from there, so the main queue is also the actor.
        call.$state.removeDuplicates().dropFirst().receive(on: DispatchQueue.main).sink { [weak self] state in
            MainActor.assumeIsolated { self?.stateChanged(state) }
        }.store(in: &watchers)
        call.$muted.removeDuplicates().dropFirst().receive(on: DispatchQueue.main).sink { [weak self] muted in
            MainActor.assumeIsolated { self?.mutedChanged(muted) }
        }.store(in: &watchers)
        call.$activity.removeDuplicates().dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.readContext() }
        }.store(in: &watchers)
        call.$working.combineLatest(call.$lastError).dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.drawActivity() }
        }.store(in: &watchers)
        // Every assignment, not only changes: the same failure twice is two failures.
        call.$lastError.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] error in
            MainActor.assumeIsolated { self?.errorChanged(error) }
        }.store(in: &watchers)
    }

    var tile: LiveTalkTile { retry.tile(callIsActive: call.isActive) }

    /// The scene connected with a call already up: show it, and hand it to the car.
    func showIfActive() {
        guard call.isActive else { return }
        Task { await call.carryOn(on: .carplay) }
        present()
        readContext()
    }

    /// Talk to Zimmer: the open conversation with voice on, or a new one. `opening` is a line
    /// put to the model as the call comes up — a tapped session's row.
    func start(opening: String? = nil) {
        retryWait?.cancel()
        retry.asked()
        self.opening = opening
        attempt()
        onChange?()
    }

    private func attempt() {
        let opening = self.opening
        Task {
            if call.isActive, let conversation = call.conversationID {
                await call.start(conversation, opening: opening, from: .carplay)
                // A row tapped meanwhile has its own opening still to send.
                if self.opening == opening { self.opening = nil }
                present()
                return
            }
            do {
                let api = AppEnvironment.shared.connection.api.live(from: .carplay)
                let id: Int
                if let current = try await api.liveConversations().current {
                    id = current
                } else {
                    id = try await api.startLiveConversation(.voice).id
                }
                await call.start(id, opening: opening, from: .carplay)
            } catch {
                failed((error as? ZimmerError)?.userMessage ?? "Couldn't start the call.", retryable: true)
            }
        }
    }

    /// The driver hung up: nothing is retried after it.
    func hangUp() {
        retryWait?.cancel()
        retry.stopped()
        opening = nil
        call.hangUp()
        onChange?()
    }

    /// The scene is going away: the call carries on on the phone; only the screen is dropped.
    func disconnect() {
        if call.isActive { Task { await call.carryOn(on: .ios) } }
        retryWait?.cancel()
        retry.stopped()
        contextRead?.cancel()
        rebuild?.cancel()
        watchers.removeAll()
        navigator = nil
        template = nil
        drawn = nil
    }

    // MARK: - Failing quietly

    private func errorChanged(_ error: String?) {
        // An error while the call is up is shown in the bar (`drawActivity`); one that ended the
        // call is a failure. A call the phone started is the phone's to retry.
        guard let error, !call.isActive, call.surface == .carplay else { return }
        // The microphone switched off for Zimmer stays off however often the car retries.
        failed(error, retryable: error != LiveAudioEngine.Failure.microphoneDenied.description)
    }

    private func failed(_ reason: String, retryable: Bool) {
        log.error("live call from the car failed: \(reason, privacy: .public)")
        if !retryable { retry.gaveUp() }
        guard retryable, let wait = retry.failed() else {
            onChange?()
            return
        }
        onChange?()
        retryWait?.cancel()
        retryWait = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self, self.retry.wanted else { return }
            if self.call.isActive {
                // A call started meanwhile (on the phone, say) is the conversation now.
                self.retry.stopped()
            } else {
                self.attempt()
            }
            self.onChange?()
        }
    }

    // MARK: - The screen

    private func stateChanged(_ state: LiveVoiceState) {
        if state == .listening {
            opening = nil
            retry.connected()
        }
        onChange?()
        if state == .idle {
            dismiss()
            subjectRouteMissing = false
            context.sessions = []
            onEnd?()
            return
        }
        if template == nil {
            present()
        } else {
            activate()
        }
    }

    private func mutedChanged(_ muted: Bool) {
        context.muted = muted
        scheduleRebuild(after: .zero)
    }

    private func present() {
        guard let navigator, template == nil, call.isActive else { return }
        context.muted = call.muted
        let fresh = build()
        template = fresh
        drawn = context
        Task {
            let shown = await navigator.present(fresh)
            guard self.template === fresh else { return }
            if shown {
                self.activate()
                self.drawActivity()
            } else {
                // A presentation CarPlay refused leaves no screen: forget the template, so the
                // next state change presents again rather than activating a state nobody sees.
                self.template = nil
                self.drawn = nil
            }
        }
        readContext()
    }

    private func dismiss() {
        rebuild?.cancel()
        guard let navigator, let template else { return }
        self.template = nil
        drawn = nil
        Task { await navigator.dismiss(template) }
    }

    /// Every call state, each with its picture, its title with the subject and muted, and the
    /// two buttons — so a state change is one `activate`, never a rebuild. Five states: CarPlay
    /// ignores any after the fifth.
    private func build() -> CPVoiceControlTemplate {
        let muted = context.muted
        let states = LiveCallScreen.states.map { state -> CPVoiceControlState in
            let voiceState = CPVoiceControlState(
                identifier: LiveCallScreen.identifier(for: state),
                titleVariants: context.titleVariants(for: state),
                image: CarPlayImages.voice(state, muted: muted),
                repeats: false
            )
            if #available(iOS 26.4, *) {
                voiceState.actionButtons = [
                    CarPlayImages.actionButton(muted ? "Unmute" : "Mute", symbol: muted ? "mic.slash.fill" : "mic.fill") { [weak self] _ in
                        self?.call.toggleMute()
                    },
                    CarPlayImages.actionButton("Hang up", symbol: "phone.down.fill") { [weak self] _ in self?.hangUp() },
                ]
            }
            return voiceState
        }
        return CPVoiceControlTemplate(voiceControlStates: states)
    }

    private func activate() {
        guard call.isActive else { return }
        template?.activateVoiceControlState(withIdentifier: LiveCallScreen.identifier(for: call.state))
    }

    /// What the call is doing, or what went wrong, as a label in the bar: the one text here
    /// that changes in place.
    private func drawActivity() {
        guard #available(iOS 26.4, *), let template else { return }
        let line = call.lastError ?? call.working
        template.trailingNavigationBarButtons = line.map { text in
            let label = CPBarButton(title: text) { _ in }
            label.isEnabled = false
            return [label]
        } ?? []
    }

    // MARK: - The subject

    /// The call relayed a tool call or recorded a line: read which sessions the conversation
    /// has touched. Coalesced, because a tool call and its result arrive within a second.
    private func readContext() {
        guard let conversation = call.conversationID, !subjectRouteMissing else { return }
        contextRead?.cancel()
        contextRead = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            do {
                let sessions = try await AppEnvironment.shared.connection.api.liveConversationSessions(conversation)
                guard !Task.isCancelled, let self else { return }
                self.context.sessions = sessions
                self.scheduleRebuild()
            } catch let ZimmerError.http(status, _) where status == 404 {
                // A server from before this route: the call has no subject to show, and is not
                // asked again.
                self?.subjectRouteMissing = true
            } catch {
                // A read that failed keeps the subject it had: a blink to no subject says nothing true.
            }
        }
    }

    private func scheduleRebuild(after delay: Duration = .seconds(1.5)) {
        guard let drawn, template != nil, context.differs(from: drawn) else { return }
        rebuild?.cancel()
        rebuild = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self, self.call.isActive else { return }
            self.represent()
        }
    }

    /// The template on screen is replaced by one whose titles say the new subject, or muted.
    private func represent() {
        guard let navigator, let old = template else { return }
        let fresh = build()
        template = fresh
        drawn = context
        Task {
            let shown = await navigator.replace(old, with: fresh)
            guard self.template === fresh else { return }
            if shown {
                self.activate()
                self.drawActivity()
            } else {
                self.template = nil
                self.drawn = nil
                // The old screen was gone (the call ended, or CarPlay refused): a call still
                // up gets a screen again.
                self.present()
            }
        }
    }
}
