import CarPlay
import Foundation
import ZimmerKit
import os

/// Zimmer in the car, as a CarPlay **voice-based conversational app**
/// (`com.apple.developer.carplay-voice-based-conversation`, iOS 26.4+). The design is
/// `ios/CARPLAY_DESIGN.md`; the rules are `DrivingBoard` (ZimmerKit, tested on Linux); the
/// screens are `CarPlayDashboard` and `CarPlayLive`. This is the wiring.
///
/// Silent until asked. The car opens on the home tab and says nothing: Zimmer speaks only after
/// the driver taps something. The one thing to hit without thinking is *Talk to Zimmer*, the
/// first tile: Live Mode, the Realtime call, which can triage, answer, start work and follow up
/// by voice. *Briefing* speaks what needs the driver, on request. Everything else is a tap or
/// two on large targets, each confirmed out loud once tapped: a decision card's *Go ahead*,
/// *Merge*, *Restart*, *Archive*, and *Talk about it*, which opens the call on that session.
///
/// The board is read again every minute while the car is connected, and after every action or
/// call, silently: the Needs you badge and the tile counts change, and nothing is said.
/// CarPlay shows no notifications for this category; the counts are how the car is proactive.
///
/// CarPlay connects the scene declared in Info.plist only in a build that signs in the
/// entitlement: `App/Zimmer/CarPlay.entitlements`, which `ios/bin/testflight` signs into every
/// TestFlight build. A simulator build carries none; see ios/README.md, "CarPlay".
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private let speech = CarPlaySpeech()
    private var dashboard: CarPlayDashboard?
    private var live: CarPlayLive?
    private var announcement: CarPlayAnnouncement?
    private var board = DrivingBoard.empty
    /// Why the last read failed, so the Briefing tile says that rather than "nothing needs you".
    private var failure: String?
    private var refreshLoop: Task<Void, Never>?
    private var refreshing: Task<Void, Never>?
    /// Which read `refreshing` is, so a read from before a reconnect cannot clear a newer one.
    private var reads = 0
    private let log = Logger(subsystem: "com.tadasant.zimmer", category: "carplay")

    /// How often the board is read while connected.
    private static let refreshEvery: Duration = .seconds(60)

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        let dashboard = CarPlayDashboard()
        dashboard.interfaceController = interfaceController
        dashboard.onTalk = { [weak self] in self?.talk() }
        dashboard.onBriefing = { [weak self] in self?.brief() }
        dashboard.onAction = { [weak self] action, card in self?.perform(action, on: card) }
        dashboard.onOpen = { [weak self] card in Task { await self?.speech.speak(card.spoken) } }
        self.dashboard = dashboard

        let live = CarPlayLive()
        live.interfaceController = interfaceController
        live.onChange = { [weak self] in
            let active = LiveCall.shared.isActive
            self?.dashboard?.callIsActive = active
            // A call started on the phone takes the voice: the car stops talking.
            if active {
                self?.speech.stop()
                self?.announcement?.dismiss()
            }
        }
        live.onEnd = { [weak self] in self?.refresh() }
        live.onFailure = { [weak self] message in
            self?.dashboard?.alert(message)
            Task { await self?.speech.speak(message) }
        }
        self.live = live

        let announcement = CarPlayAnnouncement(speech: speech)
        announcement.interfaceController = interfaceController
        announcement.onTalk = { [weak self] opening in self?.talk(opening: opening) }
        self.announcement = announcement

        dashboard.callIsActive = LiveCall.shared.isActive
        interfaceController.setRootTemplate(dashboard.tabBar, animated: false, completion: nil)

        // A call already running (started on the phone) is the conversation: show it.
        live.showIfActive()
        refresh()
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.refreshEvery)
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        refreshLoop?.cancel()
        refreshing?.cancel()
        refreshing = nil
        speech.stop()
        announcement?.dismiss()
        live?.disconnect()
        dashboard = nil
        live = nil
        announcement = nil
        self.interfaceController = nil
    }

    // MARK: - The board

    /// Read the board again, soon, and silently. One read at a time; a second ask while one
    /// runs is dropped, because the loop reads again in a minute anyway.
    private func refresh() {
        guard refreshing == nil else { return }
        reads += 1
        let mine = reads
        refreshing = Task { [weak self] in
            await self?.read()
            guard let self, self.reads == mine else { return }
            self.refreshing = nil
        }
    }

    private func read() async {
        let connection = AppEnvironment.shared.connection
        guard await connection.auth.isSignedIn else {
            failed("Sign in to Zimmer on your phone first.")
            return
        }
        do {
            let filters = BoardFilters(statuses: [.needsInput, .failed, .running, .waiting])
            // The board as the person sees it: visible sessions, each with its status summary.
            let result = try await connection.api.sessions(filters, board: .onBoard, view: .yourBoard)
            guard !Task.isCancelled else { return }
            let fresh = DrivingBoard(sessions: result.sessions)
            board = fresh
            failure = nil
            dashboard?.show(fresh)
            live?.needsYou = fresh.needsYouTotal + fresh.failedTotal
        } catch {
            log.error("refresh failed: \(String(describing: error), privacy: .public)")
            failed((error as? ZimmerError)?.userMessage ?? "Couldn't reach Zimmer.")
        }
    }

    /// The lists say why, and the Briefing tile will say it too; nothing is said unasked.
    private func failed(_ reason: String) {
        failure = reason
        dashboard?.show(failure: reason)
    }

    /// The Briefing tile: what needs the driver, from the board as last read — or why it could
    /// not be read. The one time the car speaks without a session named, and only when asked.
    private func brief() {
        Task { [weak self] in
            guard let self, let announcement = self.announcement, !(self.live?.isActive ?? false) else { return }
            let text = self.failure.map { Briefing.failure($0) } ?? Briefing.text(for: self.board)
            await announcement.announce(text, titleVariants: ["Zimmer briefing", "Briefing"], talkTitle: "Talk to Zimmer", opening: nil)
        }
    }

    // MARK: - Live Mode

    private func talk(opening: String? = nil) {
        speech.stop()
        announcement?.dismiss()
        live?.start(opening: opening)
    }

    // MARK: - A card's buttons

    private func perform(_ action: DrivingAction, on card: DrivingCard) {
        if let question = action.confirmation(for: card) {
            dashboard?.confirm(question, action: action) { [weak self] in self?.run(action, on: card) }
        } else {
            run(action, on: card)
        }
    }

    private func run(_ action: DrivingAction, on card: DrivingCard) {
        switch action {
        case .talkAboutIt:
            talk(opening: DrivingAction.opening(for: card))
        case .readAloud:
            speech.stop()
            Task { await speech.speak(card.spoken) }
        case .goAhead, .merge, .restart, .archive:
            Task { await act(action, on: card) }
        }
    }

    /// The actions that touch Zimmer. A tap is the car, so the session is told so; it says
    /// nothing about how, because a tap is not dictation. Success is spoken and the card closes,
    /// since the session has left Needs you; a failure is spoken, and the card stays.
    private func act(_ action: DrivingAction, on card: DrivingCard) async {
        let api = AppEnvironment.shared.connection.api
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let source = ClientSource.app(version: version).onCarPlay(modality: nil)
        do {
            switch action {
            case .goAhead:
                _ = try await api.followUp(card.id, prompt: DrivingAction.goAheadText, from: source)
            case .merge:
                _ = try await api.authorizeMerge(card.id)
            case .restart:
                _ = try await api.restart(card.id)
            case .archive:
                _ = try await api.archive(card.id)
            case .talkAboutIt, .readAloud:
                return
            }
            dashboard?.close(card: card.id)
            refresh()
            if let done = action.spokenDone { await speech.speak(done) }
        } catch {
            log.error("\(action.title, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            let message = (error as? ZimmerError)?.userMessage ?? "That didn't work."
            dashboard?.alert(message)
            await speech.speak(message)
        }
    }
}
