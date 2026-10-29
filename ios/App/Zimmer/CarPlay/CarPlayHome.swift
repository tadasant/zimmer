import CarPlay
import Foundation
import ZimmerKit

/// The car's one screen when no call is up: a grid with a single button, *Talk to Zimmer*.
///
/// That is the whole app outside a call, on purpose. A tab bar, the Needs you and Running
/// lists, their counts and the per-session rows were each one more template CarPlay could
/// refuse a change to, and none of them was something to do while driving: Live Mode answers
/// "what needs me?" and acts on sessions itself. The button is also where the car says Live
/// Mode is not there (*Retrying…*, *Tap to retry*), never a voice.
@MainActor
final class CarPlayHome {
    let template: CPGridTemplate
    var onTalk: (() -> Void)?

    var talkTile = LiveTalkTile.ready {
        didSet { if talkTile != oldValue { draw() } }
    }

    init() {
        template = CPGridTemplate(title: "Zimmer", gridButtons: [])
        draw()
    }

    private func draw() {
        let talk = CPGridButton(titleVariants: talkTile.titleVariants, image: CarPlayImages.tile(talkTile.symbol)) { [weak self] _ in
            self?.onTalk?()
        }
        template.updateGridButtons([talk])
    }
}
