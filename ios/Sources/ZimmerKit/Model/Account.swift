import Foundation

/// `GET /api/v1/me`: who the app's token is, what the Settings page's Sign-in card shows for
/// that person, and the page's Deployment Information.
public struct Account: Codable, Hashable, Sendable {
    /// The credential the request came in on. For the app it names a person and how they
    /// let the app act; for an API key it names the key and nobody.
    public struct Me: Codable, Hashable, Sendable {
        public struct KeyRef: Codable, Hashable, Sendable {
            public var id: Int
            public var name: String
            public var source: String
            public var grant: String

            public init(id: Int, name: String, source: String, grant: String) {
                self.id = id
                self.name = name
                self.source = source
                self.grant = grant
            }
        }

        public var authenticatedAs: String
        public var email: String?
        public var privilege: String?
        public var actsAsYou: Bool
        /// The caller's own row in the connections list, which also flags it `current`.
        public var grantID: Int?
        public var apiKey: KeyRef?

        enum CodingKeys: String, CodingKey {
            case email, privilege
            case authenticatedAs = "authenticated_as"
            case actsAsYou = "acts_as_you"
            case grantID = "grant_id"
            case apiKey = "api_key"
        }

        public init(authenticatedAs: String, email: String?, privilege: String?, actsAsYou: Bool, grantID: Int?, apiKey: KeyRef? = nil) {
            self.authenticatedAs = authenticatedAs
            self.email = email
            self.privilege = privilege
            self.actsAsYou = actsAsYou
            self.grantID = grantID
            self.apiKey = apiKey
        }

        /// The connections list's label for how this sign-in acts.
        public var privilegeLabel: String { OAuthGrant.privilegeLabel(actsAsYou: actsAsYou) }
    }

    /// The Sign-in card for the signed-in email: nil when web sign-in is off, when nobody
    /// with that email has signed in to the web UI, or on a sign-in that does not act as you.
    public struct WebSignIn: Codable, Hashable, Sendable {
        public var email: String
        public var name: String?
        public var lastSignedInAt: Date?
        public var totpRequired: Bool
        /// Nil until an authenticator stands, as the card omits the line.
        public var totpEnrolledAt: Date?
        public var recoveryCodesRemaining: Int?

        enum CodingKeys: String, CodingKey {
            case email, name
            case lastSignedInAt = "last_signed_in_at"
            case totpRequired = "totp_required"
            case totpEnrolledAt = "totp_enrolled_at"
            case recoveryCodesRemaining = "recovery_codes_remaining"
        }

        public init(email: String, name: String? = nil, lastSignedInAt: Date? = nil, totpRequired: Bool, totpEnrolledAt: Date? = nil, recoveryCodesRemaining: Int? = nil) {
            self.email = email
            self.name = name
            self.lastSignedInAt = lastSignedInAt
            self.totpRequired = totpRequired
            self.totpEnrolledAt = totpEnrolledAt
            self.recoveryCodesRemaining = recoveryCodesRemaining
        }

        /// The card's "3 recovery codes left", nil until an authenticator stands.
        public var recoveryCodesLine: String? {
            guard totpEnrolledAt != nil, let remaining = recoveryCodesRemaining else { return nil }
            return "\(remaining) recovery code\(remaining == 1 ? "" : "s") left"
        }
    }

    /// The page's Deployment Information, read once when the server booted.
    public struct Deployment: Codable, Hashable, Sendable {
        public struct Git: Codable, Hashable, Sendable {
            public var commitSha: String
            public var commitShort: String
            public var branch: String
            /// As `git log --format=%ci` prints it; the page shows it verbatim.
            public var commitDate: String?

            enum CodingKeys: String, CodingKey {
                case branch
                case commitSha = "commit_sha"
                case commitShort = "commit_short"
                case commitDate = "commit_date"
            }

            public init(commitSha: String, commitShort: String, branch: String, commitDate: String?) {
                self.commitSha = commitSha
                self.commitShort = commitShort
                self.branch = branch
                self.commitDate = commitDate
            }
        }

        public struct Environment: Codable, Hashable, Sendable {
            public var railsEnv: String
            public var rubyVersion: String
            public var railsVersion: String

            enum CodingKeys: String, CodingKey {
                case railsEnv = "rails_env"
                case rubyVersion = "ruby_version"
                case railsVersion = "rails_version"
            }

            public init(railsEnv: String, rubyVersion: String, railsVersion: String) {
                self.railsEnv = railsEnv
                self.rubyVersion = rubyVersion
                self.railsVersion = railsVersion
            }
        }

        public var git: Git
        public var environment: Environment

        public init(git: Git, environment: Environment) {
            self.git = git
            self.environment = environment
        }
    }

    public var me: Me
    public var webSignIn: WebSignIn?
    public var deployment: Deployment

    enum CodingKeys: String, CodingKey {
        case me, deployment
        case webSignIn = "web_sign_in"
    }

    public init(me: Me, webSignIn: WebSignIn?, deployment: Deployment) {
        self.me = me
        self.webSignIn = webSignIn
        self.deployment = deployment
    }
}

/// One row of Settings → API keys' **MCP connections** (`GET /api/v1/oauth_grants`): a client
/// that connected over OAuth, the person who approved it, and how it may act.
public struct OAuthGrant: Codable, Hashable, Sendable, Identifiable {
    public static let actAsHuman = "act_as_human"
    public static let relayOnly = "relay_only"

    public var id: Int
    /// The client's own name for itself, untrusted; nil when it gave none.
    public var clientName: String?
    /// That, or "Unnamed client".
    public var clientLabel: String
    public var clientID: String
    public var firstParty: Bool
    /// `published` (described by a metadata document at its client_id URL) or `self_registered`.
    public var registration: String
    public var publisherHost: String?
    public var userEmail: String
    public var privilege: String
    public var actsAsYou: Bool
    /// `active` or `revoked`.
    public var status: String
    /// The caller's own connection: the phone this app is on.
    public var current: Bool
    public var createdAt: Date
    public var lastUsedAt: Date?
    public var scopeChangedAt: Date?
    public var scopeChangeReason: String?
    public var revokedAt: Date?
    public var revocationReason: String?

    enum CodingKeys: String, CodingKey {
        case id, registration, privilege, status, current
        case clientName = "client_name"
        case clientLabel = "client_label"
        case clientID = "client_id"
        case firstParty = "first_party"
        case publisherHost = "publisher_host"
        case userEmail = "user_email"
        case actsAsYou = "acts_as_you"
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
        case scopeChangedAt = "scope_changed_at"
        case scopeChangeReason = "scope_change_reason"
        case revokedAt = "revoked_at"
        case revocationReason = "revocation_reason"
    }

    public init(id: Int, clientName: String?, clientLabel: String, clientID: String, firstParty: Bool, registration: String,
                publisherHost: String?, userEmail: String, privilege: String, actsAsYou: Bool, status: String, current: Bool,
                createdAt: Date, lastUsedAt: Date?, scopeChangedAt: Date? = nil, scopeChangeReason: String? = nil,
                revokedAt: Date? = nil, revocationReason: String? = nil) {
        self.id = id
        self.clientName = clientName
        self.clientLabel = clientLabel
        self.clientID = clientID
        self.firstParty = firstParty
        self.registration = registration
        self.publisherHost = publisherHost
        self.userEmail = userEmail
        self.privilege = privilege
        self.actsAsYou = actsAsYou
        self.status = status
        self.current = current
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.scopeChangedAt = scopeChangedAt
        self.scopeChangeReason = scopeChangeReason
        self.revokedAt = revokedAt
        self.revocationReason = revocationReason
    }

    public var isRevoked: Bool { status == "revoked" }

    /// The page's badge: "Acts on your behalf" or "Relay only".
    public static func privilegeLabel(actsAsYou: Bool) -> String { actsAsYou ? "Acts on your behalf" : "Relay only" }
    public var privilegeLabel: String { Self.privilegeLabel(actsAsYou: actsAsYou) }

    /// The page's registration badge: "Published by <host>" or "Self-registered".
    public var registrationLabel: String {
        if registration == "published", let publisherHost { return "Published by \(publisherHost)" }
        return "Self-registered"
    }

    /// The page's words for why the level last changed.
    public var scopeChangeLabel: String? {
        guard let reason = scopeChangeReason else { return nil }
        switch reason {
        case "consent": return "chosen at approval"
        case "ui_downgrade": return "lowered on the web page"
        case "ui_upgrade": return "raised on the web page"
        case "app_downgrade": return "lowered from the iOS app"
        case "app_upgrade": return "raised from the iOS app"
        case "backfill": return "raised by the one-time backfill of existing connections"
        default: return reason
        }
    }

    /// The page's question before a connection is raised to act on the approver's behalf.
    public var raiseConfirmation: String {
        "Record every message \(clientName ?? "this client") sends to a session as written by \(userEmail)? "
            + "A merge gate may treat them as that person's approval, and anything that steers the assistant can then speak as them."
    }

    /// The page's question before a revoke; the phone's own connection is a sign-out.
    public var revokeConfirmation: String {
        if current {
            return "Revoke this phone's connection? The app signs out, and has to sign in again to reconnect."
        }
        return "Revoke \(clientName ?? "this client")'s connection? It is refused from the next request on, and has to be approved again to reconnect."
    }
}

/// One row of Settings → API keys' **Keys** (`GET /api/v1/api_keys`): a key by name and
/// fingerprint, never the key itself.
public struct APIKey: Codable, Hashable, Sendable, Identifiable {
    public static let envVar = "ZIMMER_API_KEYS"
    public static let apiGrant = "api"
    public static let quickRouterGrant = "quick_router"
    /// What a person may mint, in the page's order.
    public static let formGrants = [apiGrant, quickRouterGrant]

    public struct ExternalApp: Codable, Hashable, Sendable {
        public var id: Int
        public var name: String

        public init(id: Int, name: String) {
            self.id = id
            self.name = name
        }
    }

    public var id: Int
    public var name: String
    /// `active`, `revoked`, or `retired` (an env entry no longer in the variable).
    public var status: String
    /// `env` or `minted`.
    public var source: String
    public var grant: String
    /// The first eight characters of the key's SHA-256: the page's way of matching a key you
    /// hold to its row.
    public var fingerprint: String
    public var externalApp: ExternalApp?
    /// The key this deployment writes into every agent session's Zimmer MCP servers.
    public var agentSessionsUseIt: Bool
    public var lastUsedAt: Date?
    public var createdAt: Date
    public var revokedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, status, source, grant, fingerprint
        case externalApp = "external_app"
        case agentSessionsUseIt = "agent_sessions_use_it"
        case lastUsedAt = "last_used_at"
        case createdAt = "created_at"
        case revokedAt = "revoked_at"
    }

    public init(id: Int, name: String, status: String, source: String, grant: String, fingerprint: String, externalApp: ExternalApp? = nil,
                agentSessionsUseIt: Bool, lastUsedAt: Date?, createdAt: Date, revokedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.status = status
        self.source = source
        self.grant = grant
        self.fingerprint = fingerprint
        self.externalApp = externalApp
        self.agentSessionsUseIt = agentSessionsUseIt
        self.lastUsedAt = lastUsedAt
        self.createdAt = createdAt
        self.revokedAt = revokedAt
    }

    public var isRevoked: Bool { status == "revoked" }
    public var isRetired: Bool { status == "retired" }
    public var isEnv: Bool { source == "env" }
    public var isQuickRouter: Bool { grant == Self.quickRouterGrant }

    /// The page's status badge.
    public var statusLabel: String {
        switch status {
        case "revoked": return "Revoked"
        case "retired": return "Retired"
        default: return "Active"
        }
    }

    /// The page's source badge: the variable's name for an env key, "Minted" for one made here.
    public var sourceLabel: String { isEnv ? Self.envVar : "Minted" }

    /// The page's question before a revoke, graver for the key every agent session holds.
    public var revokeConfirmation: String {
        if agentSessionsUseIt {
            return "Revoke \(name)? Every agent session uses this key for its Zimmer MCP servers — they will all lose them until the key is restored or the deployment's self-session key is replaced."
        }
        if isEnv {
            return "Revoke \(name)? Agent sessions carry every \(Self.envVar) entry in their environment, so a script of theirs may be using it. Requests carrying it are refused from the next one on. You can restore it here."
        }
        return "Revoke \(name)? Requests carrying it are refused from the next one on. You can restore it here."
    }
}

/// `POST /api/v1/api_keys`: the row, and the only copy of the key there will ever be.
public struct MintedAPIKey: Hashable, Sendable {
    public var key: APIKey
    public var token: String

    public init(key: APIKey, token: String) {
        self.key = key
        self.token = token
    }
}

/// `DELETE /api/v1/oauth_grants/:id`: the row as revoked, and whether it was the caller's own,
/// in which case the app has signed itself out.
public struct GrantRevocation: Hashable, Sendable {
    public var grant: OAuthGrant
    public var signedOut: Bool
    public var message: String

    public init(grant: OAuthGrant, signedOut: Bool, message: String) {
        self.grant = grant
        self.signedOut = signedOut
        self.message = message
    }
}

/// `POST /api/v1/sign_out_everywhere`: every web sign-in as the caller ended, and the
/// caller's own connection revoked with them.
public struct SignOutEverywhereResult: Hashable, Sendable {
    public var webSignInsEnded: Int
    public var thisConnectionRevoked: Bool
    public var message: String

    public init(webSignInsEnded: Int, thisConnectionRevoked: Bool, message: String) {
        self.webSignInsEnded = webSignInsEnded
        self.thisConnectionRevoked = thisConnectionRevoked
        self.message = message
    }
}
