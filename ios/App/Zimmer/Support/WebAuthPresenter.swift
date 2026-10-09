import AuthenticationServices
import UIKit
import ZimmerKit

/// Opens a URL in the system sign-in sheet and returns the `com.tadasant.zimmer:` callback
/// it ended on. Used for both sign-ins — Zimmer's OAuth on the web origin and the edge's
/// Cloudflare Access handoff on the app origin — so the app delegate and a background
/// request can raise it too, not only a SwiftUI view.
///
/// Not ephemeral: the sheet shares Safari's cookies, so the Google session from one
/// sign-in carries into the other and a renewal is usually a flash rather than a login.
@MainActor
final class WebAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = WebAuthPresenter()

    private var current: ASWebAuthenticationSession?

    func present(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: OAuthSignIn.callbackScheme) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else {
                    continuation.resume(throwing: error ?? ZimmerError.signIn("The sign-in sheet closed without an answer."))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            current = session
            if !session.start() {
                continuation.resume(throwing: ZimmerError.signIn("The sign-in sheet could not open."))
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let windows = scenes.flatMap(\.windows)
            return windows.first(where: \.isKeyWindow) ?? windows.first ?? ASPresentationAnchor()
        }
    }

    /// The presenter ZimmerKit's edge credential takes.
    nonisolated static let presenter: CloudflareAccessCredential.Presenter = { url in
        try await WebAuthPresenter.shared.present(url)
    }
}
