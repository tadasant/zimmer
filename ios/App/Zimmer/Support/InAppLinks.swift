import SwiftUI

/// How a tapped link reaches `AppModel.openInApp`: set once over the tabs, read by what draws
/// links people write (`MarkdownText`). An environment value rather than the model itself, so
/// a view drawn where the model was never passed opens links as any link, rather than crashing
/// on a missing environment object.
struct InAppLinks: Sendable {
    /// True when the link was one of Zimmer's own pages and its screen is open.
    var open: @MainActor @Sendable (URL) -> Bool = { _ in false }
}

private struct InAppLinksKey: EnvironmentKey {
    static let defaultValue = InAppLinks()
}

extension EnvironmentValues {
    var inAppLinks: InAppLinks {
        get { self[InAppLinksKey.self] }
        set { self[InAppLinksKey.self] = newValue }
    }
}

extension View {
    /// Links to Zimmer's own pages open on the app's screens; every other link, as before.
    func opensZimmerLinksInApp() -> some View {
        modifier(OpensZimmerLinksInApp())
    }
}

private struct OpensZimmerLinksInApp: ViewModifier {
    @Environment(\.inAppLinks) private var links

    func body(content: Content) -> some View {
        content.environment(\.openURL, OpenURLAction { url in
            // SwiftUI calls this on the main thread, from a tap.
            MainActor.assumeIsolated { links.open(url) } ? .handled : .systemAction
        })
    }
}
