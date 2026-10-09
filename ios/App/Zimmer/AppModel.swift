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
    @Published private(set) var signedInOrigins: ServerOrigins?
    /// When the edge's credential expires, on a deployment that has one.
    @Published private(set) var edgeExpiry: Date?

    let environment: AppEnvironment
    private let log = Logger(subsystem: "com.tadasant.zimmer", category: "app")

    init(environment: AppEnvironment = .shared) {
        self.environment = environment
    }

    private var connection: AppEnvironment.Connection { environment.connection }

    var buildTarget: BuildTarget { environment.configuration.buildTarget(signedInTo: signedInOrigins) }
    var hasEdge: Bool { connection.edge != nil }

    func start() async {
        let signIn = await connection.auth.signIn
        signedInOrigins = signIn?.origins
        isSignedIn = signIn != nil
        guard signIn != nil else { return }
        // Renew the edge's credential ahead of its expiry rather than on a refused call.
        if let edge = connection.edge, await edge.needsLogin() {
            await signInToEdge()
        }
        await refreshEdgeExpiry()
        await refresh()
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        let requested = filter
        do {
            let rows = try await connection.api.sessions(requested)
            guard requested == filter else { return }
            sessions = rows
            error = nil
        } catch {
            handle(error)
        }
        await refreshEdgeExpiry()
    }

    func select(_ filter: SessionFilter) async {
        guard filter != self.filter else { return }
        self.filter = filter
        sessions = []
        await refresh()
    }

    /// Sign in to a deployment: the edge first when machine calls go to a separate app
    /// host (its credential has to ride on the token call), then Zimmer's own OAuth.
    func signIn(web rawWeb: String, api rawAPI: String) async {
        guard let web = ServerURL.parse(rawWeb) else {
            error = .signIn("Enter the https address of your Zimmer, like https://zimmer.example.com.")
            return
        }
        let trimmedAPI = rawAPI.trimmingCharacters(in: .whitespaces)
        let api = trimmedAPI.isEmpty ? nil : ServerURL.parse(trimmedAPI)
        if !trimmedAPI.isEmpty && api == nil {
            error = .signIn("The app host must be an https address too, or left empty.")
            return
        }
        let origins = ServerOrigins(web: web, api: api)
        let connection = environment.connect(to: origins)
        do {
            if let edge = connection.edge, await edge.needsLogin() {
                try await edge.login()
            }
            let flow = OAuthSignIn(origins: origins)
            let callback = try await WebAuthPresenter.shared.present(flow.authorizeURL)
            try await connection.auth.complete(flow, callback: callback)
            environment.configuration.remember(origins)
            log.info("signed in to \(origins.web.host ?? "?", privacy: .public) via \(origins.api.host ?? "?", privacy: .public)")
            error = nil
            await start()
        } catch let authError as ASWebAuthenticationSessionError where authError.code == .canceledLogin {
            log.info("sign-in sheet cancelled")
        } catch {
            handle(error)
        }
    }

    /// Run the edge's handoff again — proactively near expiry, or after a refusal.
    func signInToEdge() async {
        guard let edge = connection.edge else { return }
        do {
            try await edge.login()
            if error == .edgeRefused { error = nil }
        } catch let authError as ASWebAuthenticationSessionError where authError.code == .canceledLogin {
            log.info("edge sign-in sheet cancelled")
        } catch {
            handle(error)
        }
        await refreshEdgeExpiry()
    }

    func signOut() async {
        await connection.auth.signOut()
        await connection.edge?.forget()
        sessions = []
        signedInOrigins = nil
        edgeExpiry = nil
        isSignedIn = false
    }

    private func refreshEdgeExpiry() async {
        guard let edge = connection.edge else { edgeExpiry = nil; return }
        let token = await edge.headers()["cf-access-token"]
        edgeExpiry = token.flatMap(CloudflareAccessCredential.expiry(of:))
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
