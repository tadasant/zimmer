import CarPlay
import Foundation
import ZimmerKit

/// The car's one screen when no call is up: a grid where the driver chooses, in one tap, between
/// continuing the Live Mode conversation and starting a new one.
///
/// That is the whole app outside a call, on purpose. A tab bar, the Needs you and Running
/// lists, their counts and the per-session rows were each one more template CarPlay could
/// refuse a change to, and none of them was something to do while driving: Live Mode answers
/// "what needs me?" and acts on sessions itself. The tiles are also where the car says Live Mode
/// is not there (*Retrying…*, *Tap to retry*), never a voice. Which tiles show is
/// `LiveRetry.tiles`.
///
/// Last, whenever nothing is under way, a Voice settings tile: the call screen's panel, reachable
/// before any call, so a setting can be read or put right without first making a call to open
/// it from (`LiveRetry.offersSettings`). It comes last so that it appearing or going never moves
/// a Live tile under a finger.
@MainActor
final class CarPlayHome {
    let template: CPGridTemplate
    var onTap: ((LiveTalkTile) -> Void)?
    /// The Voice settings tile.
    var onSettings: (() -> Void)?

    var tiles: [LiveTalkTile] = [.continueConversation, .newConversation] {
        didSet { if tiles != oldValue { draw() } }
    }

    var showsSettings = true {
        didSet { if showsSettings != oldValue { draw() } }
    }

    init() {
        template = CPGridTemplate(title: "Zimmer", gridButtons: [])
        draw()
    }

    private func draw() {
        var buttons = tiles.map { tile in
            CPGridButton(titleVariants: tile.titleVariants, image: CarPlayImages.tile(tile.symbol),
                         handler: CarPlayImages.tapped("tile.\(tile)") { [weak self] in self?.onTap?(tile) })
        }
        if showsSettings {
            buttons.append(CPGridButton(titleVariants: CarHomeSettingsTile.titleVariants, image: CarPlayImages.tile(CarHomeSettingsTile.symbol),
                                        handler: CarPlayImages.tapped("tile.settings") { [weak self] in self?.onSettings?() }))
        }
        template.updateGridButtons(buttons)
    }
}
