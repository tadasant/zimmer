import Foundation

/// One Zimmer the app is configured for — a "workspace", as Slack calls the same idea.
///
/// The app can be signed in to several deployments at once and shows one at a time. Each
/// deployment owns everything that is about it: its origins, its sign-in and edge login in the
/// Keychain (`signInAccount`, `edgeAccount`), and its corner of UserDefaults
/// (`defaultsKey(_:)`) — board filters, drafts, the push registration. Nothing in one is ever
/// read while another is in front, so nothing bleeds between them.
///
/// No deployment is built in: this repository names no host. The list starts empty, or with
/// the one deployment an older version of the app was signed in to (`DeploymentList.migrating`).
public struct Deployment: Codable, Hashable, Sendable, Identifiable {
    /// The id of the deployment an older, single-deployment install was signed in to. Its storage
    /// keeps the names that install used — the Keychain items and UserDefaults keys stay where
    /// they are — so updating the app moves no secret and asks nobody to sign in again.
    public static let migratedID = "primary"

    public var id: String
    /// What the switcher calls it. The host until a person renames it.
    public var name: String
    public var origins: ServerOrigins

    public init(id: String = UUID().uuidString.lowercased(), name: String? = nil, origins: ServerOrigins) {
        self.id = id
        self.origins = origins
        self.name = Self.cleaned(name) ?? Self.defaultName(for: origins)
    }

    /// The web origin's host, without a leading `www.`: what a deployment is called until it is
    /// renamed.
    public static func defaultName(for origins: ServerOrigins) -> String {
        let host = BuildTarget.host(of: origins.web) ?? origins.web.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func cleaned(_ name: String?) -> String? {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(60))
    }

    /// The host the switcher prints under the name, where calls go to.
    public var host: String { BuildTarget.host(of: origins.web) ?? origins.web.absoluteString }

    /// The avatar's letters: the first letter of each of the name's first two words (a host's
    /// labels count as words), or the first letter of a one-word name. "Workshop" is "W";
    /// "zimmer.example.com" is "ZE".
    public var initials: String {
        let words = name.split { !$0.isLetter && !$0.isNumber }
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }

    /// A stable index into a palette of `count` colours, so a deployment keeps its colour across
    /// launches and devices. FNV-1a over the id rather than `hashValue`, which Swift seeds afresh
    /// on every launch.
    public func paletteIndex(count: Int) -> Int {
        guard count > 0 else { return 0 }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Int(hash % UInt64(count))
    }

    // MARK: - Where its state lives

    /// The Keychain account its Zimmer sign-in (origins and OAuth tokens) is kept under.
    public var signInAccount: String {
        id == Self.migratedID ? "zimmer.sign-in" : "zimmer.sign-in.\(id)"
    }

    /// The Keychain account its edge login (a Cloudflare Access JWT) is kept under.
    public var edgeAccount: String {
        id == Self.migratedID ? "zimmer.edge-access-token" : "zimmer.edge-access-token.\(id)"
    }

    /// The prefix every UserDefaults key of this deployment's carries: none for the migrated one,
    /// whose keys are the ones the single-deployment app wrote.
    public var defaultsPrefix: String {
        id == Self.migratedID ? "" : "deployment.\(id)."
    }

    /// `key`, as this deployment stores it in UserDefaults.
    public func defaultsKey(_ key: String) -> String { defaultsPrefix + key }

    /// The tag a push from a deployment on `host` carries (`ApnsService#deployment_tag`): the
    /// first 16 hex digits of the SHA-256 of the lowercased host. A push names its sender this way
    /// rather than by host because Apple can read a push's payload.
    public static func pushTag(host: String) -> String {
        SHA256Digest.hash(Array(host.lowercased().utf8)).prefix(8).map { byte in
            let digits = String(byte, radix: 16)
            return digits.count == 1 ? "0" + digits : digits
        }.joined()
    }

    /// Whether a push tagged `tag` came from this deployment: its server knows itself by one of
    /// its two origins, whichever its base URL names.
    public func sent(_ tag: String) -> Bool {
        [origins.web, origins.api].compactMap { BuildTarget.host(of: $0) }.contains { Self.pushTag(host: $0) == tag }
    }
}

/// The deployments the app is configured for, in the switcher's order, and which one is in front.
public struct DeploymentList: Codable, Hashable, Sendable {
    public private(set) var deployments: [Deployment]
    public private(set) var activeID: String?

    public init(_ deployments: [Deployment] = [], activeID: String? = nil) {
        self.deployments = deployments
        self.activeID = activeID.flatMap { id in deployments.contains { $0.id == id } ? id : nil } ?? deployments.first?.id
    }

    public var active: Deployment? { deployments.first { $0.id == activeID } }
    public var isEmpty: Bool { deployments.isEmpty }

    public func deployment(_ id: String) -> Deployment? { deployments.first { $0.id == id } }

    /// The deployment already configured for these origins, so adding one twice switches to it
    /// instead. The web origin decides: it is the one a person types.
    public func existing(for origins: ServerOrigins) -> Deployment? {
        deployments.first { $0.origins.web == origins.web }
    }

    /// Add `deployment` at the end of the list and put it in front.
    public mutating func add(_ deployment: Deployment) {
        deployments.removeAll { $0.id == deployment.id }
        deployments.append(deployment)
        activeID = deployment.id
    }

    /// Put deployment `id` in front. False when there is no such deployment.
    @discardableResult
    public mutating func activate(_ id: String) -> Bool {
        guard deployments.contains(where: { $0.id == id }) else { return false }
        activeID = id
        return true
    }

    /// Take deployment `id` off the list. When it was in front, the one that took its place in
    /// the list comes forward — the next, else the previous — and with none left nothing is.
    @discardableResult
    public mutating func remove(_ id: String) -> Deployment? {
        guard let index = deployments.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = deployments.remove(at: index)
        if activeID == id {
            activeID = deployments.isEmpty ? nil : deployments[min(index, deployments.count - 1)].id
        }
        return removed
    }

    /// Move the deployments at `offsets` to before `destination`, as `List`'s `onMove` reports.
    public mutating func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let moving = offsets.filter { deployments.indices.contains($0) }.map { deployments[$0] }
        guard !moving.isEmpty else { return }
        let before = destination - offsets.filter { $0 < destination }.count
        var rest = deployments.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        rest.insert(contentsOf: moving, at: max(0, min(before, rest.count)))
        deployments = rest
    }

    /// Call deployment `id` `name`; an empty name puts back the host.
    public mutating func rename(_ id: String, to name: String) {
        guard let index = deployments.firstIndex(where: { $0.id == id }) else { return }
        deployments[index].name = Deployment.cleaned(name) ?? Deployment.defaultName(for: deployments[index].origins)
    }

    // MARK: - Pushes

    /// Where a tapped push should open.
    public enum PushRoute: Equatable, Sendable {
        /// On the deployment in front.
        case active
        /// On another configured deployment, which has to come to the front first.
        case other(Deployment)
        /// Nowhere: the push says which deployment sent it and none here is that one, or it does
        /// not say and more than one could have. Opening a session id on the wrong deployment
        /// would show some other session, so the app only comes to the front.
        case unknown
    }

    /// The deployment a push came from, by the tag its payload carries (`PushPayload.deployment`).
    public func route(forPush tag: String?) -> PushRoute {
        guard let active else { return .unknown }
        guard let tag else {
            // A server from before pushes said where they came from: only unambiguous with one.
            return deployments.count == 1 ? .active : .unknown
        }
        if active.sent(tag) { return .active }
        if let other = deployments.first(where: { $0.sent(tag) }) { return .other(other) }
        return .unknown
    }

    // MARK: - Migration

    /// The list an install starts from: the stored one, or — the first time a version of the app
    /// that knows about deployments runs — the one deployment the single-deployment app was
    /// signed in to, kept under its old storage names (`Deployment.migratedID`).
    ///
    /// `legacySignIn` is read only when nothing is stored. A legacy read that comes back empty
    /// (no sign-in, or a Keychain not yet readable after a restart) gives an empty list, which
    /// is not saved, so the migration is tried again on the next read.
    public static func load(from store: DeploymentStore, legacySignIn: () -> StoredSignIn?) -> DeploymentList {
        if let stored = store.load() { return stored }
        guard let signIn = legacySignIn() else { return DeploymentList() }
        let list = DeploymentList([Deployment(id: Deployment.migratedID, origins: signIn.origins)])
        store.save(list)
        return list
    }
}

/// Where the deployment list lives between launches. The app's is UserDefaults: it holds no
/// secret, only origins, names and the order.
public protocol DeploymentStore: Sendable {
    func load() -> DeploymentList?
    func save(_ list: DeploymentList)
}

public final class UserDefaultsDeploymentStore: DeploymentStore, @unchecked Sendable {
    public static let key = "zimmer.deployments"
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = UserDefaultsDeploymentStore.key) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> DeploymentList? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(DeploymentList.self, from: $0) }
    }

    public func save(_ list: DeploymentList) {
        defaults.set(try? JSONEncoder().encode(list), forKey: key)
    }

    /// Forget every UserDefaults key `deployment` wrote — its drafts, filters and push state —
    /// when it is removed. The migrated deployment's keys have no prefix, so they are named.
    public static func forgetDefaults(of deployment: Deployment, in defaults: UserDefaults = .standard, legacyKeys: [String]) {
        if deployment.defaultsPrefix.isEmpty {
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("draft.") || legacyKeys.contains(key) {
                defaults.removeObject(forKey: key)
            }
        } else {
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(deployment.defaultsPrefix) {
                defaults.removeObject(forKey: key)
            }
        }
    }
}

public final class InMemoryDeploymentStore: DeploymentStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: DeploymentList?
    public init(_ value: DeploymentList? = nil) { self.value = value }
    public func load() -> DeploymentList? { lock.withLock { value } }
    public func save(_ list: DeploymentList) { lock.withLock { value = list } }
}
