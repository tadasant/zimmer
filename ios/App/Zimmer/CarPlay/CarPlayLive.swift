import CarPlay
import Combine
import Foundation
import ZimmerKit

/// Live Mode in the car: the call screen, and the one way in.
///
/// The call is `LiveCall.shared`, the same one the phone's Live screen drives, so a call started
/// at the desk carries on in the car and the other way round. Starting from the car resumes the
/// open conversation with voice on, or starts a new one with voice on: one button, no choice to
/// make while driving. *Talk about it* on a session card starts the same call with an opening
/// line that names the session, so the model answers about that session first.
///
/// A call started here, or taken over from the phone, says it is `carplay` on every request,
/// so Zimmer tells the live model the person is in a car. When the car disconnects with the
/// call still up, the call carries on as the phone's again.
///
/// While the call runs the screen is a voice control template, as Apple requires of a
/// voice-based conversational app while it records. It carries what the template can carry:
///
/// - the call's state as its picture and title — connecting, listening, thinking, speaking,
///   working — with Muted said beside it;
/// - the session the conversation is about, in the title's long variant: the one the
///   conversation touched last through a tool call, read from Zimmer
///   (`GET /live_conversations/:id/sessions`) every time the call relays one;
/// - what the call is doing right now, while it is working, as a trailing bar button used as a
///   label ("Starting work…", "Checking on a session…"), because a bar button is the one text on
///   this template that can change in place;
/// - Mute and Hang up as the two action buttons iOS 26.4 allows.
///
/// A voice control state's title is fixed when the state is made, so a new subject rebuilds the
/// template and presents it in place of the old one. That is a blink, so it happens only when
/// the subject changes, and not more than once in a couple of seconds.
@MainActor
final class CarPlayLive {
    weak var interfaceController: CPInterfaceController?
    /// The call ended: the board should read again, and the home tile change back.
    var onEnd: (() -> Void)?
    /// The call could not start; the words are for an alert.
    var onFailure: ((String) -> Void)?
    /// The call's state changed, for the home tile.
    var onChange: (() -> Void)?

    private let call = LiveCall.shared
    private var template: CPVoiceControlTemplate?
    /// The context the template on screen was built from.
    private var drawn: LiveContext?
    private var context = LiveContext()
    private var watchers: Set<AnyCancellable> = []
    private var contextRead: Task<Void, Never>?
    private var rebuild: Task<Void, Never>?
    /// Moves on with every presentation, so a dismissal's completion from an earlier one
    /// presents nothing.
    private var presentation = 0
    /// The server has no `GET /live_conversations/:id/sessions` (404): asked once per call.
    private var subjectRouteMissing = false

    /// How many sessions need the driver, for the title when the call has no subject yet.
    var needsYou = 0 {
        didSet {
            context.needsYou = needsYou
            scheduleRebuild()
        }
    }

    init() {
        // LiveCall is main-actor and publishes from there.
        call.$state.removeDuplicates().dropFirst().sink { [weak self] state in
            MainActor.assumeIsolated { self?.stateChanged(state) }
        }.store(in: &watchers)
        call.$muted.removeDuplicates().dropFirst().sink { [weak self] _ in
            MainActor.assumeIsolated { self?.activate() }
        }.store(in: &watchers)
        call.$activity.removeDuplicates().dropFirst().sink { [weak self] _ in
            MainActor.assumeIsolated { self?.readContext() }
        }.store(in: &watchers)
        call.$working.combineLatest(call.$lastError).dropFirst().sink { [weak self] _ in
            MainActor.assumeIsolated { self?.drawActivity() }
        }.store(in: &watchers)
    }

    var isActive: Bool { call.isActive }

    /// The scene connected with a call already up: show it, and hand it to the car.
    func showIfActive() {
        guard call.isActive else { return }
        Task { await call.carryOn(on: .carplay) }
        present()
        readContext()
    }

    /// Talk to Zimmer: the open conversation with voice on, or a new one. `opening` is a line
    /// put to the model as the call comes up — the car's *Talk about it*.
    func start(opening: String? = nil) {
        Task {
            if call.isActive, let conversation = call.conversationID {
                await call.start(conversation, opening: opening, from: .carplay)
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
                onFailure?((error as? ZimmerError)?.userMessage ?? "Couldn't start the call.")
            }
        }
    }

    func hangUp() {
        call.hangUp()
    }

    /// The scene is going away: the call carries on on the phone; only the screen is dropped.
    func disconnect() {
        if call.isActive { Task { await call.carryOn(on: .ios) } }
        contextRead?.cancel()
        rebuild?.cancel()
        template = nil
        drawn = nil
    }

    // MARK: - The screen

    private func stateChanged(_ state: LiveVoiceState) {
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

    private func present() {
        guard let interfaceController, template == nil else { return }
        let fresh = build()
        template = fresh
        drawn = context
        presentation += 1
        let mine = presentation
        // One modal at a time: the briefing, an alert or a sheet gives way to the call.
        if interfaceController.presentedTemplate != nil {
            interfaceController.dismissTemplate(animated: false) { [weak self] _, _ in
                Task { @MainActor in
                    guard let self, let interfaceController = self.interfaceController, self.presentation == mine,
                          let fresh = self.template, self.call.isActive else { return }
                    interfaceController.presentTemplate(fresh, animated: true, completion: self.presented(mine))
                    self.activate()
                    self.drawActivity()
                }
            }
        } else {
            interfaceController.presentTemplate(fresh, animated: true, completion: presented(mine))
            activate()
            drawActivity()
        }
        readContext()
    }

    /// A presentation CarPlay refused leaves no screen: forget the template, so the next state
    /// change presents again rather than activating a state on a template nobody can see.
    private func presented(_ mine: Int) -> (Bool, Error?) -> Void {
        { [weak self] success, _ in
            guard !success else { return }
            Task { @MainActor in
                guard let self, self.presentation == mine else { return }
                self.template = nil
                self.drawn = nil
            }
        }
    }

    private func dismiss() {
        rebuild?.cancel()
        guard let interfaceController, let template else { return }
        self.template = nil
        drawn = nil
        if interfaceController.presentedTemplate === template {
            interfaceController.dismissTemplate(animated: true, completion: nil)
        }
    }

    /// Every state the call can be in, muted and not, each with its picture, its title with the
    /// subject, and the two buttons — so a state change is one `activate`, never a rebuild.
    private func build() -> CPVoiceControlTemplate {
        var states: [CPVoiceControlState] = []
        for state in [LiveVoiceState.connecting, .listening, .thinking, .speaking, .working] {
            for muted in [false, true] {
                let voiceState = CPVoiceControlState(
                    identifier: Self.identifier(state, muted: muted),
                    titleVariants: context.titleVariants(for: state, muted: muted),
                    image: CarPlayImages.voice(state, muted: muted),
                    repeats: false
                )
                if #available(iOS 26.4, *) {
                    voiceState.actionButtons = [
                        CarPlayImages.actionButton(muted ? "Unmute" : "Mute", symbol: muted ? "mic.slash.fill" : "mic.fill") { [weak self] _ in
                            self?.call.toggleMute()
                        },
                        CarPlayImages.actionButton("Hang up", symbol: "phone.down.fill") { [weak self] _ in self?.call.hangUp() },
                    ]
                }
                states.append(voiceState)
            }
        }
        return CPVoiceControlTemplate(voiceControlStates: states)
    }

    private static func identifier(_ state: LiveVoiceState, muted: Bool) -> String {
        muted ? "\(state.rawValue)-muted" : state.rawValue
    }

    private func activate() {
        guard call.isActive else { return }
        template?.activateVoiceControlState(withIdentifier: Self.identifier(call.state, muted: call.muted))
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

    private func scheduleRebuild() {
        guard let drawn, template != nil, context.differs(from: drawn) else { return }
        rebuild?.cancel()
        rebuild = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self, self.call.isActive else { return }
            self.represent()
        }
    }

    /// A new subject: the template on screen is replaced by one whose titles name it.
    private func represent() {
        guard let interfaceController, let old = template, interfaceController.presentedTemplate === old else { return }
        template = build()
        drawn = context
        presentation += 1
        let mine = presentation
        interfaceController.dismissTemplate(animated: false) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, let interfaceController = self.interfaceController, self.presentation == mine,
                      let fresh = self.template, self.call.isActive else { return }
                interfaceController.presentTemplate(fresh, animated: false, completion: self.presented(mine))
                self.activate()
                self.drawActivity()
            }
        }
    }
}
