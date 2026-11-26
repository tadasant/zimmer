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
        // A request the car made, with the phone locked or Zimmer not in front on it, has nowhere to
        // show the sheet: there is no window to anchor it to, and it would wait for an answer that
        // never comes, holding up every request behind it. Refused at once, the request fails as the
        // edge refusing the phone (`LiveBlock.signInOnPhone`) and the car says to sign in on the phone.
        guard Self.phoneIsInFront else {
            throw ZimmerError.signIn("The sign-in sheet needs Zimmer open on the phone.")
        }
        return try await withCheckedThrowingContinuation { continuation in
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

    /// The phone's own screen is showing Zimmer: a scene of the app's in the foreground. The car's
    /// scene is not a window scene and does not count.
    static var phoneIsInFront: Bool {
        UIApplication.shared.connectedScenes.contains { scene in
            scene is UIWindowScene && scene.activationState == .foregroundActive
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
