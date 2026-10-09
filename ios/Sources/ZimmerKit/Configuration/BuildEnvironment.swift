import Foundation

/// **Which deployment a build was made for, as a label rather than as a hostname.**
///
/// This repo is public and names no deployment's host — not production's and not
/// staging's. The server a build defaults to arrives at build time in
/// `ZIMMER_DEFAULT_WEB_BASE_URL` / `ZIMMER_DEFAULT_API_BASE_URL` and lands in `Info.plist`'s
/// `ZimmerDefaultWebBaseURL` / `ZimmerDefaultAPIBaseURL` (`AppConfiguration`); this is the *other* half, `ZIMMER_BUILD_ENVIRONMENT` /
/// `ZimmerBuildEnvironment`, and it carries no topology at all.
///
/// It exists because "point the build somewhere else" and "know which somewhere it was
/// pointed at" are different problems, and only the first was solved. A build that
/// defaults to staging and a build that defaults to production are byte-identical on
/// screen, so a tester, a screenshot, a bug report and an automated run could none of them
/// say which server the app in front of them was talking to. A label that is not a
/// hostname is publishable, assertable, and enough.
///
/// The host itself is still reported — by `AppConfiguration.buildTarget`, on the device that
/// holds it — so a diagnostics line on a real phone names both. What never enters this
/// repository is a *default* for either.
public enum BuildEnvironment: String, Hashable, Sendable, CaseIterable {
    /// The one a TestFlight build is, and the one an unlabelled build is assumed to be.
    case production
    /// A build whose default server is the staging deployment.
    case staging
    /// A simulator or laptop build with no default server of its own.
    case development

    /// Read the label a build was compiled with.
    ///
    /// **Unlabelled means production, and that direction is the safe one.** The two ways
    /// to be wrong are not symmetric: a staging build mistaken for production wears a
    /// badge it should not and costs a moment's confusion, while a production build
    /// mistaken for staging would wear a badge saying "this is not the real thing" over
    /// the real thing. So the default is the claim that is never a lie about the data in
    /// front of you.
    public init(label: String?) {
        let trimmed = (label ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self = BuildEnvironment(rawValue: trimmed) ?? .production
    }

    /// The chip's text, and by its nil-ness whether this build says out loud which server
    /// it is on at all. Short, because it sits in a title bar.
    ///
    /// **Production has none**: the badge is there to stop somebody trusting staging data,
    /// and a permanent "PRODUCTION" chip over a product with one user is noise.
    public var badge: String? {
        switch self {
        case .production: return nil
        case .staging: return "STAGING"
        case .development: return "DEV"
        }
    }
}

/// What a build is pointed at, as one value: the label and the host it resolved.
///
/// The host is derived rather than stored, so that a server typed on the sign-in screen
/// changes what this reports — "which environment was this build made for" and "which
/// server is it talking to right now" are different questions, and a build pointed
/// somewhere else by hand must not keep claiming its compiled-in answer.
public struct BuildTarget: Hashable, Sendable {
    public var environment: BuildEnvironment
    /// The bare host of the server in force, or nil where none is configured. A host, not a
    /// URL: it is what goes into a log line and onto a screen, and a path or a query would
    /// be neither.
    public var host: String?
    /// Whether `host` is the one this build was compiled with, rather than one typed in.
    public var isBuildDefault: Bool

    public init(environment: BuildEnvironment, host: String?, isBuildDefault: Bool) {
        self.environment = environment
        self.host = host
        self.isBuildDefault = isBuildDefault
    }

    /// `env=staging host=… source=build` — a key=value shape
    /// for one reason: one string that a log query, a screenshot and a UI test
    /// can all read.
    public var summary: String {
        [
            "env=\(environment.rawValue)",
            "host=\(host ?? "none")",
            "source=\(isBuildDefault ? "build" : "settings")",
        ].joined(separator: " ")
    }

    /// The bare host of a base URL, which is what a build target reports.
    public static func host(of url: URL?) -> String? {
        guard let url, let host = url.host(), !host.isEmpty else { return nil }
        return host.lowercased()
    }
}
