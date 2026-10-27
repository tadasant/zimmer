import CarPlay
import Foundation
import ZimmerKit
import os

/// Zimmer in the car, as a CarPlay **voice-based conversational app**
/// (`com.apple.developer.carplay-voice-based-conversation`, iOS 26.4+). The design is
/// `ios/CARPLAY_DESIGN.md`; the rules are `DrivingBoard` (ZimmerKit, tested on Linux); the
/// screens are `CarPlayDashboard` and `CarPlayLive`. This is the wiring.
///
/// Voice first, as the category requires: on connect the car reads the briefing — how many
/// sessions need the driver and the first few, how many are running — under a screen whose
/// big button is *Talk to Zimmer*. That button, on the briefing and on the home tab, is the
/// one thing to hit without thinking: Live Mode, the Realtime call, which can triage, answer,
/// start work and follow up by voice. Everything else is a tap or two on large targets, each
/// confirmed out loud: a decision card's *Go ahead*, *Merge*, *Restart*, *Archive*, and *Talk
/// about it*, which opens the call on that session.
///
/// The board is read again every minute while the car is connected, and after every action or
/// call. A session that enters Needs you while driving is spoken up about, once, with *Talk
/// about it* on the screen. CarPlay shows no notifications for this category, so that is how
/// the car is proactive.
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
    /// The Needs you ids last read, so a new arrival can be told apart; nil until the first read.
    private var known: Set<Int>?
    private var refreshLoop: Task<Void, Never>?
    private var refreshing: Task<Void, Never>?
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
        live.onChange = { [weak self] in self?.dashboard?.callIsActive = LiveCall.shared.isActive }
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

        // A call already running (started on the phone) is the conversation: show it, and skip
        // the briefing — the model is the voice now.
        live.showIfActive()
        refresh(briefing: !LiveCall.shared.isActive)
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
        speech.stop()
        announcement?.dismiss()
        live?.disconnect()
        dashboard = nil
        live = nil
        announcement = nil
        self.interfaceController = nil
    }

    // MARK: - The board

    /// Read the board again, soon. One read at a time; a second ask while one runs is dropped,
    /// because the loop reads again in a minute anyway. `briefing`: speak it once read.
    private func refresh(briefing: Bool = false) {
        guard refreshing == nil else { return }
        refreshing = Task { [weak self] in
            await self?.read(briefing: briefing)
            self?.refreshing = nil
        }
    }

    private func read(briefing: Bool) async {
        let connection = AppEnvironment.shared.connection
        guard await connection.auth.isSignedIn else {
            failed("Sign in to Zimmer on your phone first.", briefing: briefing)
            return
        }
        do {
            let filters = BoardFilters(statuses: [.needsInput, .failed, .running, .waiting])
            // The board as the person sees it: visible sessions, each with its status summary.
            let result = try await connection.api.sessions(filters, board: .onBoard, view: .yourBoard)
            let fresh = DrivingBoard(sessions: result.sessions)
            let arrivals = known.map { fresh.newlyNeedingYou(since: $0) } ?? []
            board = fresh
            known = fresh.needsYouIDs
            dashboard?.show(fresh)
            live?.needsYou = fresh.needsYouTotal + fresh.failedTotal
            if briefing {
                await announce(Briefing.text(for: fresh), titleVariants: ["Zimmer briefing", "Briefing"], talkTitle: "Talk to Zimmer", opening: nil)
            } else if let first = arrivals.first {
                await announce(Briefing.alert(for: first), titleVariants: [first.title, "Needs you"], talkTitle: "Talk about it", opening: DrivingAction.opening(for: first))
            }
        } catch {
            log.error("refresh failed: \(String(describing: error), privacy: .public)")
            failed((error as? ZimmerError)?.userMessage ?? "Couldn't reach Zimmer.", briefing: briefing)
        }
    }

    private func failed(_ reason: String, briefing: Bool) {
        dashboard?.show(failure: reason)
        if briefing {
            Task { await speech.speak(Briefing.failure(reason)) }
        }
    }

    private func announce(_ text: String, titleVariants: [String], talkTitle: String, opening: String?) async {
        guard let announcement, !(live?.isActive ?? false) else { return }
        await announcement.announce(text, titleVariants: titleVariants, talkTitle: talkTitle, opening: opening)
    }

    /// The Briefing tile: say it again, from the board as last read.
    private func brief() {
        Task { [weak self] in
            guard let self else { return }
            await self.announce(Briefing.text(for: self.board), titleVariants: ["Zimmer briefing", "Briefing"], talkTitle: "Talk to Zimmer", opening: nil)
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
