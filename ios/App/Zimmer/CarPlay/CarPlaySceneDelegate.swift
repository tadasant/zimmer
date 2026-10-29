import CarPlay
import Foundation
import ZimmerKit
import os

/// Zimmer in the car, as a CarPlay **voice-based conversational app**
/// (`com.apple.developer.carplay-voice-based-conversation`, iOS 26.4+). The design is
/// `ios/CARPLAY_DESIGN.md`; the rules are in ZimmerKit (`DrivingBoard`, `LiveCallScreen`,
/// `LiveRetry`, `CarPlayNavigator`, tested on Linux); the screens are `CarPlayDashboard` and
/// `CarPlayLive`. This is the wiring.
///
/// One thread, one voice. Everything the driver says to Zimmer goes through the one Live Mode
/// conversation, over the Realtime call, which delegates to sessions itself. The car has no
/// other voice — no system speech, no read-aloud — and no per-session buttons: a session's row
/// opens the same conversation with a line that names it.
///
/// Silent until asked. The car opens on the home tab and says nothing: the call starts only
/// when the driver taps *Talk to Zimmer* or a row.
///
/// The board is read again every minute while the car is connected, and after every call,
/// silently: the Needs you badge and the tile counts change, and nothing is said. CarPlay shows
/// no notifications for this category; the counts are how the car is proactive.
///
/// CarPlay connects the scene declared in Info.plist only in a build that signs in the
/// entitlement: `App/Zimmer/CarPlay.entitlements`, which `ios/bin/testflight` signs into every
/// TestFlight build. A simulator build carries none; see ios/README.md, "CarPlay".
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var dashboard: CarPlayDashboard?
    private var live: CarPlayLive?
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
        // A connect without the disconnect before it (CarPlay restarting the scene) starts clean.
        tearDown()

        let dashboard = CarPlayDashboard()
        dashboard.onTalk = { [weak self] in self?.live?.start() }
        dashboard.onTalkAbout = { [weak self] card in self?.live?.start(opening: card.opening) }
        self.dashboard = dashboard

        let live = CarPlayLive(interfaceController: interfaceController)
        live.onChange = { [weak self] in
            guard let self, let live = self.live else { return }
            self.dashboard?.talkTile = live.tile
        }
        live.onEnd = { [weak self] in self?.refresh() }
        self.live = live
        dashboard.talkTile = live.tile

        Task { [weak self, log] in
            do {
                try await interfaceController.setRoot(dashboard.tabBar)
            } catch {
                log.error("root template refused: \(String(describing: error), privacy: .public)")
            }
            // A call already running (started on the phone) is the conversation: show it.
            guard let self, self.live === live else { return }
            live.showIfActive()
        }
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
        tearDown()
    }

    private func tearDown() {
        refreshLoop?.cancel()
        refreshLoop = nil
        refreshing?.cancel()
        refreshing = nil
        live?.disconnect()
        dashboard = nil
        live = nil
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
            dashboard?.show(failure: "Sign in to Zimmer on your phone first.")
            return
        }
        do {
            let filters = BoardFilters(statuses: [.needsInput, .failed, .running, .waiting])
            // The board as the person sees it: visible sessions, each with its status summary.
            let result = try await connection.api.sessions(filters, board: .onBoard, view: .yourBoard)
            guard !Task.isCancelled else { return }
            let fresh = DrivingBoard(sessions: result.sessions)
            dashboard?.show(fresh)
            live?.needsYou = fresh.needsYouTotal + fresh.failedTotal
        } catch {
            log.error("refresh failed: \(String(describing: error), privacy: .public)")
            // The lists say why; nothing is said.
            dashboard?.show(failure: (error as? ZimmerError)?.userMessage ?? "Couldn't reach Zimmer.")
        }
    }
}
