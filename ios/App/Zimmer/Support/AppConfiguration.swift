import Foundation
import ZimmerKit

/// What this build was made for, and the server a person typed in instead.
///
/// No hostname is compiled in from this repository: `ZimmerDefaultBaseURL` is filled from
/// a build setting the TestFlight workflow passes, and it is empty everywhere else. A
/// person can still type a server on the sign-in screen; that one is kept in UserDefaults
/// (the sign-in itself, with its tokens, is in the Keychain).
@MainActor
final class AppConfiguration {
    private let serverKey = "zimmer.serverURL"

    static let buildDefaultBaseURL: URL? =
        ServerURL.parse(Bundle.main.object(forInfoDictionaryKey: "ZimmerDefaultBaseURL") as? String)

    static let buildEnvironment = BuildEnvironment(
        label: Bundle.main.object(forInfoDictionaryKey: "ZimmerBuildEnvironment") as? String
    )

    /// The server the sign-in screen offers: the one typed last, else the build's own.
    var serverURL: URL? {
        ServerURL.parse(UserDefaults.standard.string(forKey: serverKey)) ?? Self.buildDefaultBaseURL
    }

    func rememberServer(_ url: URL) {
        if url == Self.buildDefaultBaseURL {
            UserDefaults.standard.removeObject(forKey: serverKey)
        } else {
            UserDefaults.standard.set(url.absoluteString, forKey: serverKey)
        }
    }

    func buildTarget(signedInTo url: URL?) -> BuildTarget {
        let server = url ?? serverURL
        return BuildTarget(
            environment: Self.buildEnvironment,
            host: BuildTarget.host(of: server),
            isBuildDefault: server == nil || server == Self.buildDefaultBaseURL
        )
    }
}
