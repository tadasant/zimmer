import Foundation

/// Every way a call to Zimmer can fail, as the app needs to tell them apart.
///
/// The distinction that matters most is `.unauthorized` versus everything else: a 401 means
/// the grant is gone (revoked on Settings → API keys, or expired past its refresh token) and
/// the only fix is to sign in again, while a transport error means try again later.
public enum ZimmerError: Error, Equatable, Sendable {
    /// No server is configured, or it is not an https origin.
    case notConfigured
    /// Not signed in, or the server refused the credential and a refresh could not save it.
    case unauthorized
    /// The server answered, with a status the caller did not expect.
    case http(status: Int, message: String?)
    /// The body did not decode as what the endpoint promises.
    case decoding(String)
    /// The access proxy in front of Zimmer refused the request before Zimmer saw it
    /// (`EdgeRefusal`), and a fresh edge login did not fix it. Not a problem with the
    /// Zimmer sign-in, which is kept.
    case edgeRefused
    /// The edge's tunnel answered 404 for a path that is not on the app host's allow-list.
    /// A bug in the edge or in the app, never something to retry.
    case edgeNotRouted(String)
    /// The request never got an answer.
    case transport(String)
    /// The sign-in did not finish: refused, cancelled, or a mismatched callback.
    case signIn(String)

    public static func transport(_ error: Error) -> ZimmerError {
        .transport(String(describing: error))
    }

    /// A sentence fit for the screen.
    public var userMessage: String {
        switch self {
        case .notConfigured: return "No Zimmer server is set."
        case .unauthorized: return "Your sign-in has ended. Sign in again."
        case .edgeRefused:
            return "The network edge in front of Zimmer refused this phone. "
                + "Sign in to the edge again from Settings; your Zimmer sign-in is kept."
        case let .edgeNotRouted(path):
            return "The app host does not serve \(path). This is a bug in the app or its edge."
        case let .http(status, message): return message ?? "Zimmer answered \(status)."
        case .decoding: return "Zimmer sent something this version of the app cannot read."
        case .transport: return "Couldn't reach Zimmer."
        case let .signIn(reason): return reason
        }
    }
}

/// The error envelope every Zimmer API error carries (`Api::BaseController#render_api_error`).
struct APIErrorEnvelope: Decodable {
    let error: String?
    let message: String?
}
