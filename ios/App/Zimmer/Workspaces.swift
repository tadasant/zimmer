import AuthenticationServices
import Foundation
import SwiftUI
import UIKit
import ZimmerKit
import os

/// The deployments this phone is signed in to, and the screens for the one in front — Slack's
/// workspaces, for Zimmer.
///
/// It owns one `AppModel` at a time, the active deployment's. Switching makes a new one rather
/// than emptying the old, and `ZimmerApp` keys the whole view tree on it, so a switch reloads
/// every screen against the other deployment: no row, draft, filter, sheet, navigation path or
/// request in flight can carry over. The car and Live Mode follow `AppEnvironment.connection`,
/// which the switch also replaces, hanging up a call first.
@MainActor
final class Workspaces: ObservableObject {
    static let shared = Workspaces()

    /// The active deployment's screens.
    @Published private(set) var model: AppModel
    /// The deployments, in the switcher's order.
    @Published private(set) var list: DeploymentList
    /// The switcher sheet, opened by the avatar in the corner of the board.
    @Published var showingSwitcher = false
    /// A sign-in to a deployment being added is under way.
    @Published private(set) var isAdding = false
    /// Why the last add did not finish.
    @Published var addError: ZimmerError?

    let environment: AppEnvironment
    private var unlockObserver: NSObjectProtocol?
    private let log = Logger(subsystem: "com.tadasant.zimmer", category: "deployments")

    init(environment: AppEnvironment = .shared) {
        self.environment = environment
        list = environment.deployments
        model = AppModel(environment: environment)
        // A launch before the first unlock (a push, CarPlay) reads no list; the unlock is when it
        // can be read, whether or not the phone's screen ever comes to the front.
        unlockObserver = NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Workspaces.shared.reloadIfEmpty() }
        }
    }

    var active: Deployment? { list.active }

    /// Bring deployment `id` to the front and close the switcher.
    func switchTo(_ id: String) async {
        showingSwitcher = false
        guard await environment.activate(id) else { return }
        log.info("switched deployment")
        rebuild()
    }

    /// Add a deployment by its address: run its own sign-in — the edge's first when its machine
    /// calls go to a separate app host, then Zimmer's OAuth — and only once that has finished put
    /// it on the list, in front. An address already on the list switches to it instead. True when
    /// the deployment is now in front.
    @discardableResult
    func add(web rawWeb: String, api rawAPI: String) async -> Bool {
        let origins: ServerOrigins
        switch Self.origins(web: rawWeb, api: rawAPI) {
        case let .success(parsed): origins = parsed
        case let .failure(error):
            addError = error
            return false
        }
        if let existing = list.existing(for: origins) {
            addError = nil
            if existing.id != list.activeID { await switchTo(existing.id) } else { showingSwitcher = false }
            // Already in front and signed out: the sign-in screen for it is the one showing.
            if model.isSignedIn == false { await model.signInAgain() }
            return true
        }
        isAdding = true
        defer { isAdding = false }
        let (deployment, connection) = environment.prepare(origins)
        do {
            if !environment.isFixture {
                if let edge = connection.edge, await edge.needsLogin() {
                    try await edge.login()
                }
                let flow = OAuthSignIn(origins: origins)
                let callback = try await WebAuthPresenter.shared.present(flow.authorizeURL)
                try await connection.auth.complete(flow, callback: callback)
            }
            // Not in the fixture: what one UI test typed would be offered to the next.
            if !environment.isFixture { environment.configuration.remember(origins) }
            await environment.add(deployment, connection: connection)
            log.info("added a deployment: \(origins.web.host ?? "?", privacy: .public) via \(origins.api.host ?? "?", privacy: .public)")
            addError = nil
            showingSwitcher = false
            rebuild()
            return true
        } catch let authError as ASWebAuthenticationSessionError where authError.code == .canceledLogin {
            log.info("add-deployment sign-in cancelled")
            await environment.abandon(deployment, connection: connection)
            return false
        } catch {
            await environment.abandon(deployment, connection: connection)
            addError = error as? ZimmerError ?? .transport(error)
            return false
        }
    }

    /// Sign out of deployment `id` and take it off the list; the others stay signed in.
    func remove(_ id: String) async {
        let wasActive = list.activeID == id
        await environment.remove(id) { api, deployment in
            await PushCoordinator.shared.unregister(from: api, deployment: deployment)
        }
        list = environment.deployments
        // The switcher stays up over the deployment that came forward, showing what is left; with
        // none left there is nothing to switch to, and the sign-in screen is what comes next.
        if list.isEmpty { showingSwitcher = false }
        if wasActive { rebuild() }
    }

    func rename(_ id: String, to name: String) {
        environment.rename(id, to: name)
        list = environment.deployments
    }

    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        environment.move(fromOffsets: offsets, toOffset: destination)
        list = environment.deployments
    }

    /// Back in front with no deployment: the list may have been unreadable at launch (a push
    /// before the phone's first unlock), and is read again.
    func reloadIfEmpty() {
        if environment.reloadIfEmpty() { rebuild() }
    }

    private func rebuild() {
        list = environment.deployments
        model = AppModel(environment: environment)
    }

    /// The origins a person typed, or what is wrong with them.
    static func origins(web rawWeb: String, api rawAPI: String) -> Result<ServerOrigins, ZimmerError> {
        guard let web = ServerURL.parse(rawWeb) else {
            return .failure(.signIn("Enter the https address of your Zimmer, like https://zimmer.example.com."))
        }
        let trimmedAPI = rawAPI.trimmingCharacters(in: .whitespaces)
        let api = trimmedAPI.isEmpty ? nil : ServerURL.parse(trimmedAPI)
        if !trimmedAPI.isEmpty && api == nil {
            return .failure(.signIn("The app host must be an https address too, or left empty."))
        }
        return .success(ServerOrigins(web: web, api: api))
    }
}
