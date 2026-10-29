import CarPlay
import Foundation
import ZimmerKit
import os

/// Zimmer in the car, as a CarPlay **voice-based conversational app**
/// (`com.apple.developer.carplay-voice-based-conversation`, iOS 26.4+). The design is
/// `ios/CARPLAY_DESIGN.md`; the rules are in ZimmerKit (`LiveCallScreen`, `LiveRetry`,
/// `CarPlayNavigator`, tested on Linux); the screens are `CarPlayHome` and `CarPlayLive`. This is
/// the wiring.
///
/// Radically simple: open the app, talk to Zimmer, mute, end. One root screen with one button,
/// and one call screen that goes up when the call starts and down when it ends. Everything else
/// — what needs you, what is running, acting on a session — is the Live Mode conversation's,
/// over the Realtime call, which is the car's only voice.
///
/// Silent until asked. The car opens on the button and says nothing; the call starts only when
/// the driver taps it.
///
/// CarPlay connects the scene declared in Info.plist only in a build that signs in the
/// entitlement: `App/Zimmer/CarPlay.entitlements`, which `ios/bin/testflight` signs into every
/// TestFlight build and `ios/bin/ui-test --carplay` signs into the CarPlay drill's simulator
/// build. See ios/README.md, "CarPlay".
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var home: CarPlayHome?
    private var live: CarPlayLive?
    private let log = Logger(subsystem: "com.tadasant.zimmer", category: "carplay")

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        // A connect without the disconnect before it (CarPlay restarting the scene) starts clean.
        tearDown()
        log.notice("carplay scene connected")
        LiveTelemetry.shared.track(.carPlay("scene_connected"))

        let home = CarPlayHome()
        home.onTalk = { [weak self] in self?.live?.start() }
        self.home = home

        let live = CarPlayLive(interfaceController: interfaceController)
        live.onChange = { [weak self] in
            guard let self, let live = self.live else { return }
            self.home?.talkTile = live.tile
        }
        self.live = live
        home.talkTile = live.tile

        Task { [weak self, log] in
            do {
                try await interfaceController.setRoot(home.template)
                log.notice("carplay root template set")
            } catch {
                log.error("root template refused: \(String(describing: error), privacy: .public)")
                LiveTelemetry.shared.track(.carPlay("root_refused", level: .error, ["message": .string(String(describing: error))]))
            }
            // A call already running (started on the phone) is the conversation: show it.
            guard let self, self.live === live else { return }
            live.showIfActive()
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        log.notice("carplay scene disconnected")
        LiveTelemetry.shared.track(.carPlay("scene_disconnected"))
        LiveTelemetry.shared.flush()
        tearDown()
    }

    private func tearDown() {
        live?.disconnect()
        home = nil
        live = nil
    }
}
