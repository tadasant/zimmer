import Foundation
import ZimmerKit
import ZimmerPlatform

extension Notification.Name {
    /// Another deployment came to the front (`AppEnvironment.activate`). The CarPlay scene hears
    /// it, since it cannot observe SwiftUI state.
    static let zimmerDeploymentChanged = Notification.Name("ZimmerDeploymentChanged")
}

/// The one place the real adapters are chosen, and the deployments the app is configured for.
///
/// A singleton rather than a SwiftUI environment object because the app delegate (push
/// registration) and the CarPlay scene cannot receive environment objects, and they must
/// talk to the same signed-in session as the screens.
///
/// It holds the deployment list (`DeploymentList`) and one `Connection`: the active
/// deployment's. Switching builds a new one from that deployment's own Keychain items, so no
/// token, edge login or client is ever shared between two deployments.
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    /// Everything that talks to one deployment.
    struct Connection {
        /// Nil only before any deployment is configured.
        let deployment: Deployment?
        let auth: AuthSession
        let api: ZimmerAPI
        /// The Cloudflare Access login for a deployment whose machine calls go to a
        /// separate app host; nil when web and app are one origin.
        let edge: CloudflareAccessCredential?

        var origins: ServerOrigins? { deployment?.origins }
    }

    /// Where the Live call log goes (`LiveTelemetry+App`): the deployment in front's API. Read
    /// off the main actor, by the telemetry's own sender, so it is a lock rather than state of
    /// this class; it moves only after the log has been drained to the deployment being left.
    nonisolated static let telemetryRoute = TelemetryRoute()

    let configuration = AppConfiguration()
    private(set) var deployments: DeploymentList
    private(set) var connection: Connection {
        didSet { Self.telemetryRoute.api = connection.api }
    }
    /// True when a `#if DEBUG` launch argument swapped in the in-memory fake.
    let isFixture: Bool
    /// `-ZimmerFixtureCancelSignIn`: the fixture's add-a-deployment sign-in is closed unfinished,
    /// as a person closing the sign-in sheet does.
    let fixtureCancelsSignIn: Bool
    /// `-ZimmerFixtureEdgeNeedsAppHost`: the fixture's add-a-deployment sign-in, with the App host
    /// left empty, is refused as a web origin behind Cloudflare Access refuses the token call.
    let fixtureEdgeNeedsAppHost: Bool

    private let transport = URLSessionTransport()
    private let store: DeploymentStore
    /// The fixture's connection for a deployment, made once and kept, so switching back and forth
    /// keeps what was done to each fake.
    private var fixtureConnections: [String: Connection] = [:]
    private var makeFixtureConnection: ((Deployment, _ signedIn: Bool) -> Connection)?

    private init() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-ZimmerFixture") {
            isFixture = true
            fixtureCancelsSignIn = arguments.contains("-ZimmerFixtureCancelSignIn")
            fixtureEdgeNeedsAppHost = arguments.contains("-ZimmerFixtureEdgeNeedsAppHost")
            let fixture = Self.fixture(arguments: arguments, transport: transport)
            store = InMemoryDeploymentStore(fixture.list)
            deployments = fixture.list
            makeFixtureConnection = fixture.connect
            connection = Connection(deployment: nil, auth: AuthSession(store: InMemoryTokenStore(), transport: transport),
                                    api: FakeZimmerAPI(), edge: nil)
            connection = deployments.active.map { fixtureConnection(for: $0) } ?? connection
            Self.telemetryRoute.api = connection.api
            return
        }
        #endif

        isFixture = false
        fixtureCancelsSignIn = false
        fixtureEdgeNeedsAppHost = false
        store = UserDefaultsDeploymentStore()
        deployments = DeploymentList.load(from: store) {
            KeychainTokenStore(account: Deployment.migratedAccount).load()
        }
        connection = Self.unconfigured(transport: transport)
        connection = deployments.active.map { makeConnection(for: $0) } ?? connection
        Self.telemetryRoute.api = connection.api
    }

    // MARK: - The deployment in front

    /// Read the list again when it came back empty: before the phone's first unlock after a
    /// restart neither UserDefaults nor the Keychain can be read, and a push or CarPlay can launch
    /// the app then. True when that found deployments.
    func reloadIfEmpty() -> Bool {
        guard deployments.isEmpty, !isFixture else { return false }
        deployments = DeploymentList.load(from: store) {
            KeychainTokenStore(account: Deployment.migratedAccount).load()
        }
        guard let active = deployments.active else { return false }
        connection = makeConnection(for: active)
        return true
    }

    /// Put deployment `id` in front: a new connection from its own stores, and every call, the
    /// car's included, goes there from now on. The one going to the back is left first
    /// (`leaveFront`), so nothing of its Live call reaches the other.
    @discardableResult
    func activate(_ id: String) async -> Bool {
        guard id != deployments.activeID, deployments.deployment(id) != nil else { return false }
        await leaveFront()
        // Asked again: another switch may have happened while the call log drained.
        guard id != deployments.activeID, let deployment = deployments.deployment(id) else { return false }
        deployments.activate(id)
        store.save(deployments)
        connection = connectionFor(deployment)
        NotificationCenter.default.post(name: .zimmerDeploymentChanged, object: nil)
        return true
    }

    // MARK: - Adding, renaming, ordering and removing

    /// A connection for a deployment not on the list yet, to sign in through. Its tokens go to its
    /// own Keychain items; nothing changes for the deployment in front until `add` is called.
    func prepare(_ origins: ServerOrigins) -> (Deployment, Connection) {
        let deployment = Deployment(origins: origins)
        return (deployment, connectionFor(deployment, signedIn: true))
    }

    /// Put a deployment that has just been signed in to on the list, in front.
    func add(_ deployment: Deployment, connection: Connection) async {
        await leaveFront()
        deployments.add(deployment)
        store.save(deployments)
        self.connection = connection
        NotificationCenter.default.post(name: .zimmerDeploymentChanged, object: nil)
    }

    /// A sign-in to a deployment that was never added did not finish: forget what it stored.
    func abandon(_ deployment: Deployment, connection: Connection) async {
        guard deployments.deployment(deployment.id) == nil else { return }
        await connection.auth.signOutLocally()
        await connection.edge?.forget()
    }

    func rename(_ id: String, to name: String) {
        deployments.rename(id, to: name)
        store.save(deployments)
        if connection.deployment?.id == id, let renamed = deployments.deployment(id) {
            connection = Connection(deployment: renamed, auth: connection.auth, api: connection.api, edge: connection.edge)
        }
    }

    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        deployments.move(fromOffsets: offsets, toOffset: destination)
        store.save(deployments)
    }

    /// Sign out of deployment `id` and take it off the list: revoke its grant on its server (best
    /// effort), forget its edge login and every UserDefaults key it wrote. `beforeSignOut` runs
    /// first with the deployment's own API — the push unregistration, while its token still
    /// works. Another deployment comes to the front if this one was. The others are untouched.
    func remove(_ id: String, beforeSignOut: (ZimmerAPI, Deployment) async -> Void) async {
        guard let deployment = deployments.deployment(id) else { return }
        let wasActive = deployments.activeID == id
        // Not interactive when it is not the one in front: removing it must never raise its
        // edge's sign-in sheet.
        let doomed = wasActive ? connection : connectionFor(deployment, interactive: false)
        if wasActive { await leaveFront() }
        await beforeSignOut(doomed.api, deployment)
        await doomed.auth.signOut()
        await doomed.edge?.forget()
        UserDefaultsDeploymentStore.forgetDefaults(of: deployment, legacyKeys: AppModel.legacyDefaultsKeys + PushCoordinator.legacyDefaultsKeys)
        fixtureConnections[id] = nil
        deployments.remove(id)
        store.save(deployments)
        if wasActive {
            connection = deployments.active.map { connectionFor($0) } ?? Self.unconfigured(transport: transport)
            NotificationCenter.default.post(name: .zimmerDeploymentChanged, object: nil)
        }
    }

    /// Before another deployment comes to the front: hang up a Live call on this one, and send
    /// the call log to this one — never to the next. The hang-up's own send is waited out (a few
    /// seconds at most), what is still waiting is sent, and anything that could not be sent is
    /// dropped rather than sent to the wrong deployment.
    private func leaveFront() async {
        if LiveCall.shared.isActive { LiveCall.shared.hangUp() }
        LiveCall.shared.personChoseElsewhere()
        let telemetry = LiveTelemetry.shared
        for _ in 0..<20 where telemetry.isSending {
            try? await Task.sleep(for: .milliseconds(150))
        }
        await telemetry.send()
        telemetry.discardPending()
    }

    // MARK: - Connections

    private func connectionFor(_ deployment: Deployment, signedIn: Bool = false, interactive: Bool = true) -> Connection {
        if isFixture { return fixtureConnection(for: deployment, signedIn: signedIn) }
        return makeConnection(for: deployment, interactive: interactive)
    }

    private func fixtureConnection(for deployment: Deployment, signedIn: Bool = false) -> Connection {
        if let made = fixtureConnections[deployment.id] { return made }
        let made = makeFixtureConnection!(deployment, signedIn)
        fixtureConnections[deployment.id] = made
        return made
    }

    private func makeConnection(for deployment: Deployment, interactive: Bool = true) -> Connection {
        let tokenStore = KeychainTokenStore(account: deployment.signInAccount)
        let edgeStore = KeychainEdgeTokenStore(account: deployment.edgeAccount)
        let presenter: CloudflareAccessCredential.Presenter = interactive
            ? WebAuthPresenter.presenter
            : { @Sendable _ in throw ZimmerError.edgeRefused }
        let edge = deployment.origins.isSplit
            ? CloudflareAccessCredential(apiBaseURL: deployment.origins.api, store: edgeStore, presenter: presenter)
            : nil
        let edgeCredential: EdgeCredential = edge ?? NoEdgeCredential()
        let auth = AuthSession(store: tokenStore, transport: transport, edge: edgeCredential)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let api = ZimmerHTTPClient(auth: auth, transport: transport, edge: edgeCredential, source: .app(version: version))
        return Connection(deployment: deployment, auth: auth, api: api, edge: edge)
    }

    /// The connection before any deployment is configured: signed in nowhere.
    private static func unconfigured(transport: HTTPTransport) -> Connection {
        let auth = AuthSession(store: InMemoryTokenStore(), transport: transport)
        return Connection(deployment: nil, auth: auth, api: ZimmerHTTPClient(auth: auth, transport: transport), edge: nil)
    }

    // MARK: - The fixture

    #if DEBUG
    /// Screens with no server and no sign-in, for the UI test and screenshots: an agent cannot
    /// complete a Google sign-in. `-ZimmerFixtureSignedOut` starts with no deployment, on the
    /// sign-in screen; `-ZimmerFixtureDeployments` with two, Workshop in front and Lab behind it,
    /// each its own in-memory Zimmer; `-ZimmerFixtureRelayOnly` is a sign-in that does not act as
    /// you, so Settings → MCP Apps is refused.
    private static func fixture(arguments: [String], transport: HTTPTransport)
        -> (list: DeploymentList, connect: (Deployment, Bool) -> Connection) {
        let origins = AppConfiguration.buildDefaultOrigins ?? ServerOrigins(web: URL(string: "https://fixture.invalid")!)
        var list = DeploymentList()
        if !arguments.contains("-ZimmerFixtureSignedOut") {
            if arguments.contains("-ZimmerFixtureDeployments") {
                list = DeploymentList([
                    Deployment(id: "workshop", name: "Workshop", origins: origins),
                    Deployment(id: "lab", name: "Lab", origins: ServerOrigins(web: URL(string: "https://lab.invalid")!)),
                ])
                if arguments.contains("-ZimmerFixtureLabInFront") { list.activate("lab") }
            } else {
                list = DeploymentList([Deployment(id: "fixture", origins: origins)])
            }
        }
        let trashedElsewhere = value(after: "-ZimmerFixtureTrashedElsewhere", in: arguments).flatMap(Int.init)
        // `-ZimmerFixtureRefuse trash,follow_up`: those writes are refused, so a screen can
        // be seen putting back what it showed at the tap.
        let refuses = value(after: "-ZimmerFixtureRefuse", in: arguments)
            .map { Set($0.split(separator: ",").map(String.init)) } ?? []
        // `-ZimmerFixtureHold trash,open_session -ZimmerFixtureHoldIn <directory>`: those are not
        // answered until `<directory>/<name>.answer` exists (`FixtureHold`), so a screen can be
        // looked at ahead of the answer, or typed into while it is still loading.
        let holds = value(after: "-ZimmerFixtureHold", in: arguments)
            .map { Set($0.split(separator: ",").map(String.init)) } ?? []
        let hold = value(after: "-ZimmerFixtureHoldIn", in: arguments)
            .map { FixtureHold(holds, in: URL(fileURLWithPath: $0, isDirectory: true)) }
        // `-ZimmerFixtureVoiceTurnedUp`: the CarPlay drill's break-glass. The Live settings are
        // as voice calls left them on the call that broke (a cap of 180, eagerness low, a
        // threshold Semantic ignores, plus a gated Listening), and the first call holds on
        // Connecting… so the call screen stays up to be driven. The drill ends that call itself,
        // with the gear, so the hold is the drill's whole time allowance (`ios/bin/ui-test`): a
        // hold that runs out first fails the call under the steps still driving it.
        let voiceTurnedUp = arguments.contains("-ZimmerFixtureVoiceTurnedUp")
        // `-ZimmerFixtureCarScript`: a call held on Connecting… for as long as a test needs it.
        let carScript = arguments.contains("-ZimmerFixtureCarScript")
        let connect: (Deployment, Bool) -> Connection = { deployment, _ in
            // Every fixture deployment is signed in: the add flow's sheet is a sign-in the fixture
            // cannot run, so adding one in the fixture succeeds at once.
            let signedIn = StoredSignIn(origins: deployment.origins,
                                        tokens: OAuthTokens(accessToken: "fixture", refreshToken: nil, expiresAt: .distantFuture))
            let auth = AuthSession(store: InMemoryTokenStore(signedIn), transport: transport)
            // Lab has a board of its own; every other deployment, one added in a test included,
            // gets the usual sample board.
            let isLab = deployment.id == "lab"
            let api = FakeZimmerAPI(
                sessions: isLab ? FakeZimmerAPI.otherDeploymentSessions() : FakeZimmerAPI.sampleSessions(),
                live: arguments.contains("-ZimmerFixtureLive"),
                longTranscript: arguments.contains("-ZimmerFixtureLongTranscript"),
                relayOnly: arguments.contains("-ZimmerFixtureRelayOnly"), degraded: arguments.contains("-ZimmerFixtureDegraded"),
                trashedElsewhere: trashedElsewhere,
                refuses: refuses, hold: hold,
                liveSettings: voiceTurnedUp ? ["voice_max_output_tokens": .number(180), "voice_vad_eagerness": .string("low"), "voice_vad_threshold": .number(0.92), "voice_listening": .string("dynamic")] : [:],
                liveSecretHold: voiceTurnedUp || carScript ? .seconds(600) : nil,
                liveStartHold: voiceTurnedUp ? .seconds(45) : nil,
                web: deployment.origins.web)
            return Connection(deployment: deployment, auth: auth, api: api, edge: nil)
        }
        return (list, connect)
    }

    /// The argument after `flag`: what a launch argument that takes a value was given.
    private static func value(after flag: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }
    #endif
}

extension Deployment {
    /// The Keychain account the single-deployment app kept its sign-in under, read once to
    /// migrate it (`DeploymentList.load`).
    static var migratedAccount: String {
        Deployment(id: migratedID, origins: ServerOrigins(web: URL(string: "https://migrating.invalid")!)).signInAccount
    }
}

/// The API the Live call log is sent to, readable from any thread.
final class TelemetryRoute: @unchecked Sendable {
    private let lock = NSLock()
    private var current: ZimmerAPI?

    var api: ZimmerAPI? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}
