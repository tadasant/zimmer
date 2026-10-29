import CarPlay
import Combine
import Foundation
import ZimmerKit
import os

/// Live Mode in the car: the call screen, and the one thing the car does.
///
/// The call is `LiveCall.shared`, the same one the phone's Live screen drives, so a call started
/// at the desk carries on in the car and the other way round. Talk to Zimmer resumes the open
/// conversation with voice on, or starts a new one with voice on: one button, no choice to make
/// while driving.
///
/// A call started here, or taken over from the phone, says it is `carplay` on every request,
/// so Zimmer tells the live model the person is in a car. When the car disconnects with the
/// call still up, the call carries on as the phone's again.
///
/// **When the call cannot connect, or drops, the car says so on the Talk button and tries
/// again, quietly** (`LiveRetry`): *Live Mode unavailable, retrying…*, then *Tap to retry* once
/// the retries are spent. It never speaks with another voice: the Realtime call is the car's
/// only voice.
///
/// While the call runs the screen is a voice control template, as Apple requires of a
/// voice-based conversational app while it records, and it is kept minimal:
///
/// - the call's state as its picture and title — connecting, listening, thinking, speaking,
///   working — one state each, the five CarPlay keeps (`LiveCallScreen`);
/// - one line in the bar, the one text on this template that changes in place: an error, or
///   Muted and what the call is doing ("Starting work…");
/// - Mute and End, the two action buttons iOS 26.4 allows.
///
/// The template is built once per call, put up when the call starts and taken down when it
/// ends. It is never rebuilt: every template change is one more CarPlay can refuse, and each
/// goes through `CarPlayNavigator`, one at a time, because a refused change with no completion
/// is a crash.
@MainActor
final class CarPlayLive {
    /// The call's state, or the retry's, changed: the Talk button should say so.
    var onChange: (() -> Void)?

    private let call = LiveCall.shared
    private var navigator: CarPlayNavigator<CPInterfaceController>?
    private var template: CPVoiceControlTemplate?
    private var watchers: Set<AnyCancellable> = []
    private(set) var retry = LiveRetry()
    private var retryWait: Task<Void, Never>?
    private let log = Logger(subsystem: "com.tadasant.zimmer", category: "carplay-live")

    init(interfaceController: CPInterfaceController) {
        let navigator = CarPlayNavigator(host: interfaceController)
        navigator.onError = { [log] message in log.error("\(message, privacy: .public)") }
        self.navigator = navigator
        // A `@Published` property publishes in its `willSet`, before the value is stored, so a
        // sink that reads the call (`isActive`, `state`, `lastError`) would read the state it
        // is leaving. Each sink is received on the main queue's next turn instead, when every
        // property says the same thing: the screen activates the state the call is in, and the
        // button counts a call that just ended as ended. LiveCall is main-actor and publishes
        // from there, so the main queue is also the actor.
        call.$state.removeDuplicates().dropFirst().receive(on: DispatchQueue.main).sink { [weak self] state in
            MainActor.assumeIsolated { self?.stateChanged(state) }
        }.store(in: &watchers)
        call.$muted.combineLatest(call.$working, call.$lastError).dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.drawLine() }
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
    }

    /// Talk to Zimmer: the open conversation with voice on, or a new one.
    func start() {
        retryWait?.cancel()
        retry.asked()
        attempt()
        onChange?()
    }

    private func attempt() {
        Task {
            if call.isActive, let conversation = call.conversationID {
                await call.start(conversation, from: .carplay)
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
                await call.start(id, from: .carplay)
            } catch {
                failed((error as? ZimmerError)?.userMessage ?? "Couldn't start the call.", retryable: true)
            }
        }
    }

    /// The driver ended the call: nothing is retried after it.
    func hangUp() {
        retryWait?.cancel()
        retry.stopped()
        call.hangUp()
        onChange?()
    }

    /// The scene is going away: the call carries on on the phone; only the screen is dropped.
    func disconnect() {
        if call.isActive { Task { await call.carryOn(on: .ios) } }
        retryWait?.cancel()
        retry.stopped()
        watchers.removeAll()
        navigator = nil
        template = nil
    }

    // MARK: - Failing quietly

    private func errorChanged(_ error: String?) {
        // An error while the call is up is shown on the line (`drawLine`); one that ended the
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
        if state == .listening { retry.connected() }
        onChange?()
        if state == .idle {
            dismiss()
        } else if template == nil {
            present()
        } else {
            activate()
        }
    }

    private func present() {
        guard let navigator, template == nil, call.isActive else { return }
        let fresh = build()
        template = fresh
        Task {
            let shown = await navigator.present(fresh)
            guard self.template === fresh else { return }
            if shown {
                self.activate()
                self.drawLine()
            } else {
                // A presentation CarPlay refused leaves no screen: forget the template, so the
                // next state change presents again rather than activating a state nobody sees.
                self.template = nil
            }
        }
    }

    private func dismiss() {
        guard let navigator, let template else { return }
        self.template = nil
        Task { await navigator.dismiss(template) }
    }

    /// Every call state, each with its picture, its title and the two buttons, so a state change
    /// is one `activate`. Five states: CarPlay ignores any after the fifth.
    private func build() -> CPVoiceControlTemplate {
        let states = LiveCallScreen.states.map { state -> CPVoiceControlState in
            let voiceState = CPVoiceControlState(
                identifier: LiveCallScreen.identifier(for: state),
                titleVariants: [LiveCallScreen.title(for: state)],
                image: CarPlayImages.voice(state),
                repeats: false
            )
            if #available(iOS 26.4, *) {
                voiceState.actionButtons = [
                    CarPlayImages.actionButton("Mute", symbol: "mic.slash.fill") { [weak self] _ in self?.call.toggleMute() },
                    CarPlayImages.actionButton("End", symbol: "phone.down.fill") { [weak self] _ in self?.hangUp() },
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

    /// The one line in the bar: an error, or Muted and what the call is doing.
    private func drawLine() {
        guard #available(iOS 26.4, *), let template else { return }
        let line = LiveCallScreen.line(error: call.lastError, working: call.working, muted: call.muted)
        template.trailingNavigationBarButtons = line.map { text in
            let label = CPBarButton(title: text) { _ in }
            label.isEnabled = false
            return [label]
        } ?? []
    }
}
