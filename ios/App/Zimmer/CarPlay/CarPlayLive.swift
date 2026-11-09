import CarPlay
import Combine
import Foundation
import ZimmerKit
import os

/// Live Mode in the car: the call screen, and the one thing the car does.
///
/// The call is `LiveCall.shared`, the same one the phone's Live screen drives, so a call started
/// at the desk carries on in the car and the other way round. The home's two tiles are the
/// driver's choice, one tap each with no confirmation: Continue calls the open conversation with
/// voice on, New ends it and calls a fresh one (`CarLiveChoice`). With nothing open there is only
/// New. An ended conversation stays readable, so New needs no alert, which would be one more
/// modal for CarPlay to refuse.
///
/// A call started here, or taken over from the phone, says it is `carplay` on every request,
/// so Zimmer tells the live model the person is in a car. When the car disconnects with the
/// call still up, the call carries on as the phone's again, and the phone goes to it
/// (`LiveCall.carLeft`, `LiveHandover`).
///
/// **When the call cannot connect, or drops, the car says so on the home's tile and tries
/// again** (`LiveRetry`): *Live Mode unavailable, retrying…*, then *Tap to retry* once the retries
/// are spent. The falling notes sound at the first failure and when it gives up, so a driver
/// knows without looking. It never speaks with another voice: the Realtime call is the car's only
/// voice.
///
/// While the call runs the screen is a voice control template, as Apple requires of a
/// voice-based conversational app while it records, and it is kept minimal:
///
/// - the call's state as its picture and title — Connecting…, Listening, Hearing you, Replying,
///   or Muted while the microphone is off: the five states CarPlay keeps (`LiveCallScreen`);
/// - Mute and End, the two action buttons iOS 26.4 allows, with **Send now** in Mute's place
///   while the driver is heard and turn detection has not ended the turn (Hearing you);
/// - a gear, the leading bar button, to the voice settings.
///
/// **Send now ends the driver's turn when turn detection has not.** One tap, no confirmation:
/// the speech heard so far goes up and the reply is asked for (`LiveCall.sendNow`,
/// `RealtimeConductor.endTurn`). It is there only while there is speech to send, so it is never
/// on screen while Zimmer replies, and a tap that arrives after the turn ended anyway sends
/// nothing. The heard cue says it went; there is nothing to read.
///
/// **The gear ends the call, and closing the panel brings it back.** CarPlay allows recording only
/// with the voice control template on screen, and a list cannot be presented over it: it is
/// pushed, and the call screen has to come down first. So the call hangs up, which closes the
/// microphone and releases the audio session, and when the panel closes the same conversation
/// is called again, muted if it was muted. That call is minted from the row the panel wrote, so
/// every change takes effect then, the ones OpenAI fixes for a call's life included. Listening is
/// the exception: a car call is built as Always, so it reaches only calls started on the phone.
///
/// The template is built once per call, put up when the call starts and taken down when it
/// ends. It is never rebuilt, and Mute is a state like the others: every template change is one
/// more CarPlay can refuse, and each goes through `CarPlayNavigator`, one at a time, because a
/// refused change with no completion is a crash.
@MainActor
final class CarPlayLive {
    /// The call's state, the retry's, or what Zimmer has open changed: the tiles should say so.
    var onChange: (() -> Void)?

    private let call = LiveCall.shared
    private var navigator: CarPlayNavigator<CPInterfaceController>?
    private var template: CPVoiceControlTemplate?
    private var watchers: Set<AnyCancellable> = []
    private(set) var retry = LiveRetry()
    private var retryWait: Task<Void, Never>?
    /// What the driver last chose. A retry or a drop asks again through this, not through a tile.
    private var wish = CarLiveWish()
    /// Whether Zimmer has a conversation to continue, nil until it has said.
    private var conversationOpen: Bool?
    private var openRead: Task<Void, Never>?
    /// The voice settings, from the gear until the panel closes.
    private var settings: CarPlayVoiceSettings?
    /// The panel is on the stack, so CarPlay going back to the root means it was closed.
    private var settingsOnStack = false
    #if DEBUG
    /// How many scenes have put a call screen up. The drill unplugs the car from the first.
    private static var drillScenes = 0
    private var drillPressedTheGear = false
    /// What CarPlay runs for a tap on the gear, for the drill to run the same way.
    private var drillGear: (press: (CPBarButton) -> Void, button: CPBarButton)?
    /// What CarPlay runs for a tap on Send now, for the drill to run the same way.
    private var drillSendNow: ((CPButton) -> Void)?
    /// The drill is showing Send now's state on a call that never hears anyone.
    private var drillHearing = false
    #endif
    /// The panel is closing, waiting for the driver's last write.
    private var settingsClosing = false
    /// The call the gear ended, to bring back. Kept until OpenAI has answered on the new call,
    /// because a retry is still bringing back that conversation.
    private var comeback: CarCallComeback?
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
            MainActor.assumeIsolated { self?.muteChanged() }
        }.store(in: &watchers)
        call.$microphoneLost.removeDuplicates().dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.activate() }
        }.store(in: &watchers)
        // Speech heard, or the turn ended: Send now comes and goes with it.
        call.$canSendNow.removeDuplicates().dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.activate() }
        }.store(in: &watchers)
        // Every assignment, not only changes: the same failure twice is two failures.
        call.$lastError.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] error in
            MainActor.assumeIsolated { self?.errorChanged(error) }
        }.store(in: &watchers)
    }

    var tiles: [LiveTalkTile] { retry.tiles(callIsActive: call.isActive, conversationOpen: conversationOpen) }

    /// Whether there is anything to continue, for the tiles. Only a read, so the car stays
    /// silent, and only once the driver has stopped asking for a call: until then the tiles are
    /// showing what the car is doing. One that fails, or is skipped, leaves the tiles as they
    /// are, and the tap reads again.
    func readWhatIsOpen() {
        guard !call.isActive, !retry.wanted else { return }
        let api = AppEnvironment.shared.connection.api.live(from: .carplay)
        openRead?.cancel()
        openRead = Task {
            guard let overview = try? await api.liveConversations(), !Task.isCancelled, self.navigator != nil else { return }
            self.conversationOpen = overview.current != nil
            self.onChange?()
        }
    }

    /// The scene connected with a call already up: show it, and hand it to the car.
    func showIfActive() {
        guard call.isActive else { return }
        // The car's call now: if it drops, the car calls back, as for one it started.
        retry.asked()
        retry.connected()
        Task { await call.carryOn(on: .carplay) }
        present()
    }

    /// A tile: the conversation the driver chose, or the same wish again from a tile reporting
    /// on it. The first tap holds until it has its conversation, so a second is not a second
    /// conversation.
    func start(_ tile: LiveTalkTile) {
        telemetry.track(.carPlay("talk_tapped", ["call_active": .bool(call.isActive), "tile": .string(String(describing: tile))]))
        comeback?.talkTapped()
        guard !retry.lookingUp else { return }
        wish.tapped(tile, callIsActive: call.isActive)
        // A fresh start is asked for out loud: a mute left over from the call it replaces would
        // open a new conversation on a microphone that hears nothing. Retry keeps it.
        if wish.choice == .startNew { comeback = nil }
        openRead?.cancel()
        retryWait?.cancel()
        retry.asked()
        attempt()
        onChange?()
    }

    private func attempt() {
        guard !retry.lookingUp else { return }
        // Before the first await, so that a tap arriving during one finds it set.
        retry.lookup()
        Task {
            // CarPlay's Back can leave the panel with a write still out: no call reads the row
            // ahead of it, a tile's included.
            await settings?.settled()
            // That can take as long as the write does, and the car may have gone or the driver
            // ended it meanwhile: a call started now would have no screen to be seen on.
            guard navigator != nil, retry.wanted else {
                retry.lookedUp()
                onChange?()
                return
            }
            if call.isActive, let conversation = call.conversationID {
                retry.lookedUp()
                await call.start(conversation, from: .carplay)
                present()
                return
            }
            if let conversation = comeback?.conversation {
                retry.lookedUp()
                await call.start(conversation, startsMuted: comeback?.muted == true, from: .carplay)
                return
            }
            onChange?()
            do {
                let found = try await conversationToCall()
                retry.lookedUp()
                wish.answered()
                guard let found else {
                    nothingToContinue()
                    return
                }
                conversationOpen = true
                guard retry.wanted else {
                    onChange?()
                    return
                }
                await call.start(found, startsMuted: comeback?.muted == true, from: .carplay)
            } catch {
                retry.lookedUp()
                guard retry.wanted else {
                    onChange?()
                    return
                }
                failed((error as? ZimmerError)?.userMessage ?? "Couldn't start the call.", retryable: true)
            }
        }
    }

    /// The driver's choice as a conversation. This comes before the call exists, so the call's
    /// own deadline does not cover it: it gets the same one here, and a request still out when
    /// that passes is cancelled.
    private func conversationToCall() async throws -> Int? {
        let api = AppEnvironment.shared.connection.api.live(from: .carplay)
        let lookup = Task { [choice = wish.choice] () throws -> Int? in
            try await api.conversation(for: choice)
        }
        let deadline = Task {
            try await Task.sleep(for: .seconds(LiveCallHealth.connectDeadline))
            lookup.cancel()
        }
        defer { deadline.cancel() }
        return try await lookup.value
    }

    /// Continue, with nothing open: it ended on the phone since the tiles were drawn, or under a
    /// retry. The car does not start a new thread in its place, because that is not what was
    /// asked for and nothing would say so. The falling notes say no call is coming, and the
    /// tiles come down to New.
    private func nothingToContinue() {
        telemetry.track(.carPlay("nothing_to_continue", level: .warn))
        conversationOpen = false
        comeback = nil
        if retry.wanted { call.soundUnavailable() }
        retry.stopped()
        onChange?()
    }

    /// Send now. The screen the tap came from is in the log, because CarPlay may deliver a tap on
    /// a state that has just been replaced.
    private func sendNow() {
        telemetry.track(.carPlay("send_now_tapped", ["screen": .string(screenIdentifier)]))
        call.sendNow()
    }

    /// The driver ended the call: nothing is retried after it.
    func hangUp() {
        telemetry.track(.carPlay("end_tapped"))
        comeback = nil
        retryWait?.cancel()
        retry.stopped()
        call.hangUp()
        onChange?()
    }

    /// The scene is going away: the call carries on on the phone; only the screen is dropped. A
    /// call the gear ended stays ended: there is no car left to bring it back to.
    func disconnect() {
        call.carLeft()
        settings = nil
        settingsOnStack = false
        settingsClosing = false
        comeback = nil
        retryWait?.cancel()
        openRead?.cancel()
        retry.stopped()
        watchers.removeAll()
        navigator = nil
        template = nil
    }

    // MARK: - The voice settings

    /// The gear: end the call, take its screen down, and put the panel up.
    private func openSettings() {
        guard let navigator, settings == nil,
              let ended = CarCallComeback(conversation: call.conversationID, callIsActive: call.isActive, muted: call.muted) else { return }
        telemetry.track(.carPlay("settings_opened", ["state": .string(String(describing: call.state))]))
        #if DEBUG
        drillHearing = false
        #endif
        comeback = ended
        retryWait?.cancel()
        retry.stopped()
        call.hangUp()
        dismiss()
        let panel = CarPlayVoiceSettings(api: AppEnvironment.shared.connection.api.live(from: .carplay))
        panel.onClose = { [weak self] in self?.closeSettings() }
        panel.onWritten = { [telemetry] what in telemetry.track(.carPlay("settings_changed", ["what": .string(what)])) }
        settings = panel
        onChange?()
        Task {
            let shown = await navigator.push(panel.template)
            guard self.settings === panel else { return }
            if shown {
                self.settingsOnStack = true
                // CarPlay's Back may have beaten this line.
                self.settingsMayHaveClosed()
                await panel.load()
            } else {
                // No panel: the driver has lost the call for nothing, so it comes straight back.
                self.telemetry.track(.carPlay("settings_refused", level: .warn))
                self.settings = nil
                self.settingsClosing = false
                self.callBack()
            }
        }
    }

    /// The panel closed, by its own Back to the call or by CarPlay's. It waits for the driver's
    /// last write, saying Saving…, so the call is minted from what the driver chose. A write that
    /// failed keeps the panel up to say so, and the next Back closes it on what the row holds.
    /// With CarPlay's Back there is no panel left to say it on, so the log does.
    private func closeSettings() {
        guard let panel = settings, !settingsClosing else { return }
        telemetry.track(.carPlay("settings_closed"))
        settingsClosing = true
        // A failure the driver has already read does not hold them up a second time.
        let writing = panel.isSaving
        Task {
            await panel.settled()
            guard self.settings === panel else { return }
            self.settingsClosing = false
            if writing, panel.writeFailed {
                guard self.navigator?.isAtRoot == true else { return }
                self.telemetry.track(.carPlay("settings_write_lost", level: .warn))
            }
            self.settings = nil
            self.settingsOnStack = false
            await self.navigator?.pop(panel.template)
            self.callBack()
        }
    }

    private func callBack() {
        guard navigator != nil, comeback?.wantsCall == true, !call.isActive else { return }
        retry.asked()
        attempt()
        onChange?()
    }

    /// CarPlay showed a template: if that left nothing above the root, the driver went Back.
    func settingsMayHaveClosed() {
        guard settingsOnStack, navigator?.isAtRoot == true else { return }
        closeSettings()
    }

    /// A call started without the car, on the phone, while the panel was up: it is the
    /// conversation now, so the panel goes and the call the gear ended stays ended.
    private func dropSettings() {
        guard let panel = settings else { return }
        settings = nil
        settingsOnStack = false
        settingsClosing = false
        comeback = nil
        Task { await navigator?.pop(panel.template) }
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
            call.soundUnavailable()
            onChange?()
            return
        }
        if retry.failures == 1 { call.soundUnavailable() }
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

    private func muteChanged() {
        comeback?.muteChanged(call.muted, callIsActive: call.isActive)
        activate()
    }

    private func stateChanged(_ state: LiveVoiceState) {
        if state == .listening { retry.connected() }
        // Asked of the call, not of `state`: this runs a turn late, so a state from just before
        // the gear ended the call can arrive after the panel went up.
        if call.isActive {
            dropSettings()
            // The call is the conversation now, whoever started it, and a New left over from a
            // start that failed must not end it when this call drops.
            wish.answered()
        }
        if comeback?.isSpent(by: call.state) == true { comeback = nil }
        onChange?()
        if state == .idle {
            dismiss()
            readWhatIsOpen()
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
                #if DEBUG
                self.drillPressesTheGear()
                #endif
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
    /// Mute included — is one `activate`. Five states: CarPlay ignores any after the fifth. The
    /// gear belongs to the template rather than to a state, and is set here, once.
    private func build() -> CPVoiceControlTemplate {
        let sendNowPressed: (CPButton) -> Void = CarPlayImages.tapped("send_now") { [weak self] in self?.sendNow() }
        let states = LiveCallScreen.identifiers.map { identifier -> CPVoiceControlState in
            let voiceState = CPVoiceControlState(
                identifier: identifier,
                titleVariants: [LiveCallScreen.title(for: identifier)],
                image: CarPlayImages.voice(identifier),
                repeats: false
            )
            if #available(iOS 26.4, *) {
                // Send now takes Mute's place, so End stays where the driver's hand knows it.
                let first = identifier == LiveCallScreen.sendNowState
                    ? CarPlayImages.actionButton(LiveCallScreen.sendNowTitle, symbol: "arrow.up.circle.fill", hint: LiveCallScreen.sendNowHint, handler: sendNowPressed)
                    : CarPlayImages.actionButton("Mute", symbol: "mic.slash.fill", hint: "Turns the microphone off or on", handler: CarPlayImages.tapped("mute") { [weak self] in self?.call.toggleMute() })
                voiceState.actionButtons = [
                    first,
                    CarPlayImages.actionButton("End", symbol: "phone.down.fill", hint: "Ends the call", handler: CarPlayImages.tapped("end") { [weak self] in self?.hangUp() }),
                ]
            }
            return voiceState
        }
        let screen = CPVoiceControlTemplate(voiceControlStates: states)
        if #available(iOS 26.4, *) {
            #if DEBUG
            drillSendNow = sendNowPressed
            #endif
            let pressed: (CPBarButton) -> Void = CarPlayImages.tapped("gear") { [weak self] in self?.openSettings() }
            let gear = CPBarButton(image: CarPlayImages.bar("gearshape.fill"), handler: pressed)
            screen.leadingNavigationBarButtons = [gear]
            #if DEBUG
            drillGear = (pressed, gear)
            #endif
        }
        return screen
    }

    #if DEBUG
    /// `-ZimmerFixtureVoiceTurnedUp`, for the CarPlay drill: Send now's state and closure, then the
    /// Swift closure behind the gear, once, a while after the call screen goes up on the scene the
    /// drill reconnected, and off the main thread, the one way a tap can arrive that the Simulator
    /// never shows. XCUITest computes
    /// no hit point for a template's bar button, and a click from the Mac at its place does not
    /// reach it, so this is how the panel is driven.
    private func drillPressesTheGear() {
        guard AppEnvironment.shared.isFixture, ProcessInfo.processInfo.arguments.contains("-ZimmerFixtureVoiceTurnedUp"),
              !drillPressedTheGear else { return }
        drillPressedTheGear = true
        Self.drillScenes += 1
        guard Self.drillScenes == 2 else { return }
        // Send now's state, shown on a call the fixture holds on Connecting…, which hears nobody:
        // the drill photographs it, and its closure runs off the main thread, where it finds
        // nothing to send. Before the gear, which takes the screen down.
        Task {
            try? await Task.sleep(for: .seconds(4))
            self.drillHearing = true
            self.activate()
            try? await Task.sleep(for: .seconds(5))
            guard let press = self.drillSendNow else { return }
            nonisolated(unsafe) let pressed = press
            nonisolated(unsafe) let button = CPButton(image: CarPlayImages.bar("arrow.up.circle.fill"), handler: { _ in })
            DispatchQueue.global().async { pressed(button) }
        }
        Task {
            try? await Task.sleep(for: .seconds(25))
            guard let gear = self.drillGear else { return }
            nonisolated(unsafe) let press = gear.press
            nonisolated(unsafe) let button = gear.button
            DispatchQueue.global().async { press(button) }
        }
    }
    #endif

    private func activate() {
        guard call.isActive else { return }
        template?.activateVoiceControlState(withIdentifier: screenIdentifier)
    }

    /// The state the call screen shows for the call as it is now.
    private var screenIdentifier: String {
        #if DEBUG
        if drillHearing { return LiveCallScreen.sendNowState }
        #endif
        return LiveCallScreen.identifier(for: call.state, muted: call.muted, microphoneLost: call.microphoneLost, speechHeard: call.canSendNow)
    }
}
