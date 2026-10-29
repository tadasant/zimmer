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
/// - the call's state as its picture and title — Connecting…, Listening, Speaking, Working on
///   it…, or Muted while the microphone is off: the five states CarPlay keeps
///   (`LiveCallScreen`);
/// - Mute and End, the two action buttons iOS 26.4 allows.
///
/// The template is built once per call, put up when the call starts and taken down when it
/// ends. It is never rebuilt, and Mute is a state like the others: every template change is one
/// more CarPlay can refuse, and each goes through `CarPlayNavigator`, one at a time, because a
/// refused change with no completion is a crash.
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
    private let telemetry = LiveTelemetry.shared

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
        call.$muted.removeDuplicates().dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.activate() }
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
        telemetry.track(.carPlay("talk_tapped", ["call_active": .bool(call.isActive)]))
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
        telemetry.track(.carPlay("end_tapped"))
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
        // An error while the call is up leaves it up; one that ended the call is a failure. A call the phone started is the phone's to retry.
        guard let error, !call.isActive, call.surface == .carplay else { return }
        // The microphone switched off for Zimmer stays off however often the car retries.
        failed(error, retryable: error != LiveAudioEngine.Failure.microphoneDenied.description)
    }

    private func failed(_ reason: String, retryable: Bool) {
        log.error("live call from the car failed: \(reason, privacy: .public)")
        if !retryable { retry.gaveUp() }
        guard retryable, let wait = retry.failed() else {
            telemetry.track(.carPlay("retry_gave_up", level: .warn, ["reason": .string(reason), "retryable": .bool(retryable)]))
            onChange?()
            return
        }
        telemetry.track(.carPlay("retry_scheduled", level: .warn, ["reason": .string(reason), "wait_ms": .int(Int(wait.components.seconds * 1_000))]))
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

    /// Put the call screen up: this call's, or a new one. The driver may have closed it with
    /// CarPlay's ✕ while the call carried on; *Back to the call* puts the same one up again,
    /// and the navigator knows it is not on screen, so it presents it rather than calling it up.
    private func present() {
        guard let navigator, call.isActive else { return }
        let screen = template ?? build()
        template = screen
        Task {
            let shown = await navigator.present(screen)
            self.telemetry.track(.carPlay(shown ? "call_screen_presented" : "call_screen_refused", level: shown ? .debug : .warn))
            guard self.template === screen else { return }
            if shown {
                self.activate()
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
        telemetry.track(.carPlay("call_screen_dismissed", level: .debug))
        Task { await navigator.dismiss(template) }
    }

    /// Every state, each with its picture, its title and the two buttons, so a state change —
    /// Mute included — is one `activate`. Five states: CarPlay ignores any after the fifth.
    private func build() -> CPVoiceControlTemplate {
        let states = LiveCallScreen.identifiers.map { identifier -> CPVoiceControlState in
            let voiceState = CPVoiceControlState(
                identifier: identifier,
                titleVariants: [LiveCallScreen.title(for: identifier)],
                image: CarPlayImages.voice(identifier),
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
        template?.activateVoiceControlState(withIdentifier: LiveCallScreen.identifier(for: call.state, muted: call.muted))
    }
}
