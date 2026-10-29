import CarPlay
import UIKit
import ZimmerKit

/// The symbols the car's templates draw. CarPlay renders template images itself, in the car's
/// scale and appearance, so a symbol image is enough; the sizes are the guide's.
enum CarPlayImages {
    /// A grid tile's icon (40pt in the guide).
    static func tile(_ name: String) -> UIImage {
        symbol(name, pointSize: 40, weight: .medium)
    }

    /// The voice control template's picture for a call state (150pt in the guide).
    static func voice(_ state: LiveVoiceState) -> UIImage {
        let name: String
        switch state {
        case .idle, .connecting: name = "antenna.radiowaves.left.and.right"
        case .listening: name = "mic.fill"
        case .thinking: name = "ellipsis.bubble.fill"
        case .speaking: name = "waveform"
        case .working: name = "gearshape.2.fill"
        }
        return symbol(name, pointSize: 120, weight: .regular)
    }

    /// One of the voice control template's action buttons (iOS 26.4+): a `CPButton`, which takes
    /// an image and carries its words as a title. `CPTextButton` is a different class and is not
    /// one of these.
    @available(iOS 26.4, *)
    static func actionButton(_ title: String, symbol name: String, handler: @escaping (CPButton) -> Void) -> CPButton {
        let button = CPButton(image: symbol(name, pointSize: 24, weight: .medium), handler: handler)
        button.title = title
        return button
    }

    static func symbol(_ name: String, pointSize: CGFloat, weight: UIImage.SymbolWeight) -> UIImage {
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        return UIImage(systemName: name, withConfiguration: configuration) ?? UIImage(systemName: "circle", withConfiguration: configuration) ?? UIImage()
    }
}
