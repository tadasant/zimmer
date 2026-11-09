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

    /// The voice control template's picture for one of its states (150pt in the guide).
    static func voice(_ identifier: String) -> UIImage {
        let name: String
        switch identifier {
        case "listening": name = "mic.fill"
        case "hearing": name = "waveform.and.mic"
        case "replying": name = "waveform"
        case "muted": name = "mic.slash.fill"
        default: name = "antenna.radiowaves.left.and.right"
        }
        return symbol(name, pointSize: 120, weight: .regular)
    }

    /// One of the voice control template's action buttons (iOS 26.4+): a `CPButton`, which takes
    /// an image and carries its words as a title. `CPTextButton` is a different class and is not
    /// one of these.
    ///
    /// CarPlay draws only the symbol, and labels the button for accessibility by the symbol
    /// alone: the CarPlay drill reads "hang up" for End, and an accessibility label set on the
    /// image is not carried over. So the symbol is the button's words, and is chosen for them.
    @available(iOS 26.4, *)
    static func actionButton(_ title: String, symbol name: String, handler: @escaping (CPButton) -> Void) -> CPButton {
        let button = CPButton(image: symbol(name, pointSize: 24, weight: .medium), handler: handler)
        button.title = title
        return button
    }

    /// What a tap on `control` runs: `action`, on the main actor, whichever thread CarPlay called
    /// from (`CarPlayTap`).
    static func tapped<Control>(_ control: String, _ action: @escaping @MainActor @Sendable () -> Void) -> (Control) -> Void {
        CarPlayTap.handler(arrived: { arrived(control, onMain: $0) }, action)
    }

    /// CarPlay reached `control`'s handler. A mark, because a crash right after loses the log's
    /// events, and a line when it called off the main thread, because no test can see which thread
    /// a head unit's tap arrives on.
    static func arrived(_ control: String, onMain: Bool) {
        LiveTelemetry.shared.mark("carplay:\(control):\(onMain ? "main" : "off_main")")
        if !onMain {
            LiveTelemetry.shared.track(.carPlay("off_main", level: .warn, ["control": .string(control)]))
        }
    }

    /// A navigation bar button (the guide's bar buttons are 22pt).
    static func bar(_ name: String) -> UIImage {
        symbol(name, pointSize: 22, weight: .medium)
    }

    static func symbol(_ name: String, pointSize: CGFloat, weight: UIImage.SymbolWeight) -> UIImage {
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        return UIImage(systemName: name, withConfiguration: configuration) ?? UIImage(systemName: "circle", withConfiguration: configuration) ?? UIImage()
    }
}
