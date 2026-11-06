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
@MainActor
final class CarPlayHome {
    let template: CPGridTemplate
    var onTap: ((LiveTalkTile) -> Void)?

    var tiles: [LiveTalkTile] = [.continueConversation, .newConversation] {
        didSet { if tiles != oldValue { draw() } }
    }

    init() {
        template = CPGridTemplate(title: "Zimmer", gridButtons: [])
        draw()
    }

    private func draw() {
        let buttons = tiles.map { tile in
            CPGridButton(titleVariants: tile.titleVariants, image: CarPlayImages.tile(tile.symbol)) { [weak self] _ in
                self?.onTap?(tile)
            }
        }
        template.updateGridButtons(buttons)
    }
}
