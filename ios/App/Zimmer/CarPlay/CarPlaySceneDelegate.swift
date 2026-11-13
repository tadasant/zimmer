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
/// Radically simple: open the app, talk to Zimmer, mute, end. One root screen where the driver
/// continues the conversation or starts a new one, and one call screen that goes up when the
/// call starts and down when it ends. Everything else
/// — what needs you, what is running, acting on a session — is the Live Mode conversation's,
/// over the Realtime call, which is the car's only voice. The one exception is the gear on the
/// call screen: the voice settings, by touch, because a call that has stopped working cannot be
/// asked to fix itself (`CarPlayVoiceSettings`).
///
/// Silent until asked. The car opens on its tiles and says nothing; the call starts only when
/// the driver taps one. CarPlay pre-warm holds a connection ready from
/// the moment the scene connects (`LiveWarmKeeper`), but it sends nothing, opens no microphone and
/// shows nothing: the tap is still where the call begins.
///
/// CarPlay connects the scene declared in Info.plist only in a build that signs in the
/// entitlement: `App/Zimmer/CarPlay.entitlements`, which `ios/bin/testflight` signs into every
/// TestFlight build and `ios/bin/ui-test --carplay` signs into the CarPlay drill's simulator
/// build. See ios/README.md, "CarPlay".
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPInterfaceControllerDelegate {
    private var home: CarPlayHome?
    private var live: CarPlayLive?
    private let log = Logger(subsystem: "com.tadasant.zimmer", category: "carplay")

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        // A connect without the disconnect before it (CarPlay restarting the scene) starts clean.
        tearDown()
        // After the tear-down, which leaves any call to the phone: the car has it again.
        LiveCall.shared.carCameBack()
        log.notice("carplay scene connected")
        LiveTelemetry.shared.track(.carPlay("scene_connected"))
        // CarPlay pre-warm: holds a connection ready for Continue.
        LiveWarmKeeper.shared.carConnected()

        interfaceController.delegate = self

        let home = CarPlayHome()
        home.onTap = { [weak self] tile in self?.live?.start(tile) }
        self.home = home

        let live = CarPlayLive(interfaceController: interfaceController)
        live.onChange = { [weak self] in
            guard let self, let live = self.live else { return }
            self.home?.tiles = live.tiles
        }
        self.live = live
        home.tiles = live.tiles

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
            live.readWhatIsOpen()
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        log.notice("carplay scene disconnected")
        LiveTelemetry.shared.track(.carPlay("scene_disconnected"))
        LiveTelemetry.shared.flush()
        LiveWarmKeeper.shared.carDisconnected()
        tearDown()
    }

    /// The driver's own Back leaves the panel without telling it, and this is how the car hears.
    /// Nonisolated for the reason a tap is (`CarPlayTap`): CarPlay does not say which thread this
    /// comes in on.
    nonisolated func templateDidAppear(_ aTemplate: CPTemplate, animated: Bool) {
        CarPlayTap.run(arrived: { CarPlayImages.arrived("template_did_appear", onMain: $0) }) { [weak self] in
            self?.live?.settingsMayHaveClosed()
        }
    }

    private func tearDown() {
        live?.disconnect()
        home = nil
        live = nil
    }
}
