import AuthenticationServices
import Foundation
import SwiftUI
import ZimmerKit
import os

/// The state the screens render. It holds no networking rules and no sign-in rules — those
/// are ZimmerKit's — only what is on screen and the calls that change it.
@MainActor
final class AppModel: ObservableObject {
    /// Nil until the stored sign-in has been read.
    @Published private(set) var isSignedIn: Bool?
    @Published var filter: SessionFilter = .needsInput
    @Published private(set) var sessions: [SessionSummary] = []
    @Published private(set) var isLoading = false
    @Published var error: ZimmerError?
    @Published private(set) var signedInServer: URL?

    let environment: AppEnvironment
    private let log = Logger(subsystem: "com.tadasant.zimmer", category: "app")

    init(environment: AppEnvironment = .shared) {
        self.environment = environment
    }

    var buildTarget: BuildTarget { environment.configuration.buildTarget(signedInTo: signedInServer) }

    func start() async {
        let signIn = await environment.auth.signIn
        signedInServer = signIn?.baseURL
        isSignedIn = signIn != nil
        if signIn != nil { await refresh() }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        let requested = filter
        do {
            let rows = try await environment.api.sessions(requested)
            guard requested == filter else { return }
            sessions = rows
            error = nil
        } catch {
            handle(error)
        }
    }

    func select(_ filter: SessionFilter) async {
        guard filter != self.filter else { return }
        self.filter = filter
        sessions = []
        await refresh()
    }

    /// Run the sign-in sheet against `server`, then finish the OAuth exchange.
    func signIn(server raw: String, using webAuth: WebAuthenticationSession) async {
        guard let server = ServerURL.parse(raw) else {
            error = .signIn("Enter the https address of your Zimmer, like https://zimmer.example.com.")
            return
        }
        let flow = OAuthSignIn(baseURL: server)
        do {
            let callback = try await webAuth.authenticate(
                using: flow.authorizeURL,
                callbackURLScheme: OAuthSignIn.callbackScheme,
                preferredBrowserSession: .shared
            )
            try await environment.auth.complete(flow, callback: callback)
            environment.configuration.rememberServer(server)
            log.info("signed in to \(server.host ?? "?", privacy: .public)")
            error = nil
            await start()
        } catch let authError as ASWebAuthenticationSessionError where authError.code == .canceledLogin {
            log.info("sign-in sheet cancelled")
        } catch {
            handle(error)
        }
    }

    func signOut() async {
        await environment.auth.signOut()
        sessions = []
        signedInServer = nil
        isSignedIn = false
    }

    private func handle(_ error: Error) {
        let zimmerError = error as? ZimmerError ?? .transport(error)
        log.error("request failed: \(String(describing: zimmerError), privacy: .public)")
        if zimmerError == .unauthorized {
            isSignedIn = false
            sessions = []
        }
        self.error = zimmerError
    }
}
