import Foundation

/// Where a request comes from, for the note Zimmer adds to each turn an agent receives
/// ("Sent from Zimmer on CarPlay · voice dictation"), so the agent can fit its reply to
/// the medium.
///
/// A style hint and nothing more. The server takes the surface from the app's sign-in and
/// lets this header narrow `ios` to `carplay` only; the modality is the app's own word,
/// which nothing checks, so nothing on the server authorizes anything on it. Only
/// allowlisted values are sent: no device name, identifier or free text.
public struct ClientSource: Hashable, Sendable {
    public enum Surface: String, Hashable, Sendable {
        case ios
        case carplay
    }

    /// How the words were produced. Absent when the app cannot tell: the phone's composers
    /// are text fields, and iOS keyboard dictation is invisible to the app.
    public enum Modality: String, Hashable, Sendable {
        case text
        case voiceDictation = "voice_dictation"
    }

    public static let clientHeader = "X-Zimmer-Client"
    public static let modalityHeader = "X-Zimmer-Input-Modality"

    public var surface: Surface
    /// The marketing version, e.g. "1.4.2". Dropped by the server unless it is digits and dots.
    public var version: String?
    public var modality: Modality?

    public init(surface: Surface = .ios, version: String? = nil, modality: Modality? = nil) {
        self.surface = surface
        self.version = version
        self.modality = modality
    }

    /// The app on the phone: what every request carries unless a call says otherwise.
    public static func app(version: String?) -> ClientSource {
        ClientSource(surface: .ios, version: version)
    }

    /// The same app, speaking from the car.
    public func onCarPlay(modality: Modality?) -> ClientSource {
        ClientSource(surface: .carplay, version: version, modality: modality)
    }

    public var headers: [String: String] {
        var headers = [Self.clientHeader: version.map { "\(surface.rawValue)/\($0)" } ?? surface.rawValue]
        if let modality { headers[Self.modalityHeader] = modality.rawValue }
        return headers
    }
}
