import Foundation
import ZimmerKit

/// What this build was made for, and the servers a person typed in instead.
///
/// No hostname is compiled in from this repository. A distribution build gets two
/// origins from build settings the TestFlight workflow passes, both empty everywhere else:
/// `ZimmerDefaultWebBaseURL` (where a person signs in, the OAuth issuer) and
/// `ZimmerDefaultAPIBaseURL` (where machine calls go — an app hostname behind its own
/// access proxy, on a deployment that has one). Either alone means one origin for both.
/// What a person types on the sign-in screen is kept in UserDefaults; the sign-in itself,
/// with its tokens, is in the Keychain.
@MainActor
final class AppConfiguration {
    private let webKey = "zimmer.webURL"
    private let apiKey = "zimmer.apiURL"

    static let buildDefaultOrigins: ServerOrigins? = {
        let web = ServerURL.parse(Bundle.main.object(forInfoDictionaryKey: "ZimmerDefaultWebBaseURL") as? String)
        let api = ServerURL.parse(Bundle.main.object(forInfoDictionaryKey: "ZimmerDefaultAPIBaseURL") as? String)
        guard let first = web ?? api else { return nil }
        return ServerOrigins(web: first, api: api ?? first)
    }()

    static let buildEnvironment = BuildEnvironment(
        label: Bundle.main.object(forInfoDictionaryKey: "ZimmerBuildEnvironment") as? String
    )

    /// The origins the sign-in screen offers: the ones typed last, else the build's own.
    var origins: ServerOrigins? {
        if let web = ServerURL.parse(UserDefaults.standard.string(forKey: webKey)) {
            return ServerOrigins(web: web, api: ServerURL.parse(UserDefaults.standard.string(forKey: apiKey)))
        }
        return Self.buildDefaultOrigins
    }

    func remember(_ origins: ServerOrigins) {
        if origins == Self.buildDefaultOrigins {
            UserDefaults.standard.removeObject(forKey: webKey)
            UserDefaults.standard.removeObject(forKey: apiKey)
        } else {
            UserDefaults.standard.set(origins.web.absoluteString, forKey: webKey)
            UserDefaults.standard.set(origins.isSplit ? origins.api.absoluteString : nil, forKey: apiKey)
        }
    }

    /// `host` is the app origin — the one every call goes to.
    func buildTarget(signedInTo signedIn: ServerOrigins?) -> BuildTarget {
        let server = signedIn ?? origins
        return BuildTarget(
            environment: Self.buildEnvironment,
            host: BuildTarget.host(of: server?.api),
            isBuildDefault: server == nil || server == Self.buildDefaultOrigins
        )
    }
}
