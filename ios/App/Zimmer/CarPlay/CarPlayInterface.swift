import CarPlay
import Foundation
import ZimmerKit

/// The one place the CarPlay scene calls its interface controller, and only through CarPlay's
/// async calls.
///
/// CarPlay throws an exception — the app crashes — when a present, dismiss, push, pop or root
/// change fails and was given no completion (the "Discussion" of each in Apple's
/// `CPInterfaceController` documentation). The async forms always hand CarPlay a completion, so
/// a refusal comes back as an error, and the continuation brings it back to the main actor
/// whatever thread CarPlay answered on. `CarPlayTests` fails the build on any other call.
extension CPInterfaceController: CarPlayModalHost {
    public typealias Template = CPTemplate

    struct Refused: Error, CustomStringConvertible {
        let what: String
        var description: String { "CarPlay did not \(what)" }
    }

    public func present(_ template: CPTemplate, animated: Bool) async throws {
        guard try await presentTemplate(template, animated: animated) else { throw Refused(what: "present \(type(of: template))") }
    }

    public func dismissPresented(animated: Bool) async throws {
        guard try await dismissTemplate(animated: animated) else { throw Refused(what: "dismiss") }
    }

    /// The scene's root, set once on connect.
    func setRoot(_ template: CPTemplate) async throws {
        guard try await setRootTemplate(template, animated: false) else { throw Refused(what: "set the root") }
    }
}
