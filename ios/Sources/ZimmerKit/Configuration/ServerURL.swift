import Foundation

/// A Zimmer server, as the app accepts one: an https origin and nothing else.
///
/// https only, because the access token travels on every request; no path, because every
/// route the app calls is absolute from the origin. The same rule `ios/bin/build-app`
/// applies to `--api-base-url`, so a build and a typed-in value cannot disagree.
public enum ServerURL {
    public static func parse(_ raw: String?) -> URL? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else { return nil }
        components.scheme = "https"
        components.host = host.lowercased()
        components.path = ""
        return components.url
    }
}
