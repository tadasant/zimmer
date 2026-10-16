import Foundation

/// The web UI's Inference page as data (`GET /api/v1/inference?runtime=`): one runtime's
/// account roster with each account's quota windows, the pool's capacity, the rotation log,
/// the Pi tab's OpenRouter key state, and the fleet-scheduling policy. Every figure is the
/// one the page renders (`InferenceReport` on the server), so the two cannot disagree.
public struct InferenceReport: Hashable, Sendable, Decodable {
    public struct Runtime: Hashable, Sendable, Decodable, Identifiable {
        public var key: String
        public var label: String
        public var id: String { key }

        public init(key: String, label: String) {
            self.key = key
            self.label = label
        }
    }

    public static let claudeCode = "claude_code"
    public static let codex = "codex"
    public static let pi = "pi"
    /// The page's tabs, for the strip before the first read answers.
    public static let defaultRuntimes = [Runtime(key: claudeCode, label: "Claude Code"), Runtime(key: codex, label: "Codex"), Runtime(key: pi, label: "Pi")]

    public var runtime: String
    public var runtimes: [Runtime]
    /// `nil` on the Pi tab, which pools no accounts.
    public var accounts: [InferenceAccount]?
    public var pool: InferencePool?
    public var rotationLog: [RotationEvent]?
    /// On the Pi tab only.
    public var openrouterKey: OpenRouterKeyState?
    public var spotPolicy: SpotPolicy
    public var fleetTopUp: FleetTopUp
    public var genesisClasses: GenesisClasses

    enum CodingKeys: String, CodingKey {
        case runtime, runtimes, accounts, pool
        case rotationLog = "rotation_log"
        case openrouterKey = "openrouter_key"
        case spotPolicy = "spot_policy"
        case fleetTopUp = "fleet_top_up"
        case genesisClasses = "genesis_classes"
    }

    public init(runtime: String, runtimes: [Runtime] = InferenceReport.defaultRuntimes, accounts: [InferenceAccount]? = nil, pool: InferencePool? = nil,
                rotationLog: [RotationEvent]? = nil, openrouterKey: OpenRouterKeyState? = nil, spotPolicy: SpotPolicy, fleetTopUp: FleetTopUp,
                genesisClasses: GenesisClasses) {
        self.runtime = runtime
        self.runtimes = runtimes
        self.accounts = accounts
        self.pool = pool
        self.rotationLog = rotationLog
        self.openrouterKey = openrouterKey
        self.spotPolicy = spotPolicy
        self.fleetTopUp = fleetTopUp
        self.genesisClasses = genesisClasses
    }

    public var isPi: Bool { runtime == Self.pi }
    /// The spot gate and the top-up read the Claude Code quota windows, so the page shows
    /// their cards on that tab alone.
    public var showsPolicy: Bool { runtime == Self.claudeCode }

    public var runtimeLabel: String {
        runtimes.first(where: { $0.key == runtime })?.label ?? runtime
    }
}

/// One account as its card renders it.
public struct InferenceAccount: Hashable, Sendable, Decodable, Identifiable {
    /// What Zimmer knows about the stored credentials, not whether the blob is non-empty.
    public struct Credentials: Hashable, Sendable, Decodable {
        /// `none`, `unverified`, `verified` or `rejected`.
        public var state: String
        public var stored: Bool
        public var refused: Bool
        public var rejectedAt: Date?
        public var rejectionReason: String?
        public var verifiedAt: Date?

        enum CodingKeys: String, CodingKey {
            case state, stored, refused
            case rejectedAt = "rejected_at"
            case rejectionReason = "rejection_reason"
            case verifiedAt = "verified_at"
        }

        public init(state: String, stored: Bool, refused: Bool = false, rejectedAt: Date? = nil, rejectionReason: String? = nil, verifiedAt: Date? = nil) {
            self.state = state
            self.stored = stored
            self.refused = refused
            self.rejectedAt = rejectedAt
            self.rejectionReason = rejectionReason
            self.verifiedAt = verifiedAt
        }
    }

    /// One quota window as the card draws it. `status` is dropped once the window has
    /// rolled over, as the badge is.
    public struct Window: Hashable, Sendable, Decodable {
        public var utilization: Double?
        /// Zero once the window has reset, whatever the reading said.
        public var effectiveUtilization: Double?
        public var status: String?
        public var resetAt: Date?
        public var resetPassed: Bool

        enum CodingKeys: String, CodingKey {
            case utilization, status
            case effectiveUtilization = "effective_utilization"
            case resetAt = "reset_at"
            case resetPassed = "reset_passed"
        }

        public init(utilization: Double?, effectiveUtilization: Double? = nil, status: String? = nil, resetAt: Date? = nil, resetPassed: Bool = false) {
            self.utilization = utilization
            self.effectiveUtilization = effectiveUtilization ?? (resetPassed ? 0 : utilization)
            self.status = status
            self.resetAt = resetAt
            self.resetPassed = resetPassed
        }

        /// The page's "42.0%", or "N/A" with no reading.
        public var percentText: String {
            guard let value = effectiveUtilization else { return "N/A" }
            return String(format: "%.1f%%", value * 100)
        }

        /// The fraction of the bar to fill.
        public var fraction: Double { min(max(effectiveUtilization ?? 0, 0), 1) }

        /// The badge beside the window's label: "Allowed", the status in title case, or
        /// nothing once the window is gone (`InferenceHelper#window_status_badge`).
        public var badge: String? {
            guard !resetPassed, let status else { return nil }
            return status == "allowed" ? "Allowed" : status.split(separator: "_").map(\.capitalized).joined(separator: " ")
        }

        /// The line under the bar: "Window reset", or "Resets in 2h 10m".
        public func resetLine(now: Date = Date()) -> String? {
            guard let resetAt else { return nil }
            if resetPassed || resetAt <= now { return "Window reset" }
            return "Resets in \(InferenceFormat.duration(resetAt.timeIntervalSince(now)))"
        }
    }

    /// The account's latest reading. `nil` for Codex, which has no usage-quota probe.
    public struct Quota: Hashable, Sendable, Decodable {
        public var takenAt: Date?
        public var trigger: String?
        public var subscriptionType: String?
        public var rateLimitTier: String?
        public var fiveHour: Window
        public var sevenDay: Window
        /// The 5-hour bar reads as headroom the account cannot spend: its week is gone.
        public var fiveHourHeadroomUnusable: Bool

        enum CodingKeys: String, CodingKey {
            case trigger
            case takenAt = "taken_at"
            case subscriptionType = "subscription_type"
            case rateLimitTier = "rate_limit_tier"
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case fiveHourHeadroomUnusable = "five_hour_headroom_unusable"
        }

        public init(takenAt: Date?, trigger: String? = nil, subscriptionType: String? = nil, rateLimitTier: String? = nil, fiveHour: Window, sevenDay: Window,
                    fiveHourHeadroomUnusable: Bool = false) {
            self.takenAt = takenAt
            self.trigger = trigger
            self.subscriptionType = subscriptionType
            self.rateLimitTier = rateLimitTier
            self.fiveHour = fiveHour
            self.sevenDay = sevenDay
            self.fiveHourHeadroomUnusable = fiveHourHeadroomUnusable
        }
    }

    /// The card's login panel: whether the flow applies, the attempt in flight, and how the
    /// last one ended.
    public struct Login: Hashable, Sendable, Decodable {
        public struct Last: Hashable, Sendable, Decodable {
            public var id: Int
            public var status: String
            public var errorMessage: String?

            enum CodingKeys: String, CodingKey {
                case id, status
                case errorMessage = "error_message"
            }

            public init(id: Int, status: String, errorMessage: String? = nil) {
                self.id = id
                self.status = status
                self.errorMessage = errorMessage
            }
        }

        /// False for a Codex API-key account, which carries its credential statically.
        public var available: Bool
        public var activeAttempt: LoginAttempt?
        public var lastAttempt: Last?

        enum CodingKeys: String, CodingKey {
            case available
            case activeAttempt = "active_attempt"
            case lastAttempt = "last_attempt"
        }

        public init(available: Bool, activeAttempt: LoginAttempt? = nil, lastAttempt: Last? = nil) {
            self.available = available
            self.activeAttempt = activeAttempt
            self.lastAttempt = lastAttempt
        }

        /// The panel's line about the previous attempt, when it did not succeed.
        public var lastFailureLine: String? {
            guard activeAttempt == nil, let last = lastAttempt else { return nil }
            switch last.status {
            case "failed": return last.errorMessage.map { "Last login failed: \($0)" }
            case "expired": return last.errorMessage ?? "Last login expired before completion."
            default: return nil
            }
        }
    }

    public var id: Int
    public var email: String
    public var runtime: String
    public var priority: Int
    public var isCurrent: Bool
    /// The sticky column: `active`, `quota_exceeded`, `needs_reauth`.
    public var status: String
    /// The badge, which the latest reading can outrank.
    public var effectiveStatus: String
    public var quotaHitCount: Int
    public var apiKeyAccount: Bool
    public var credentials: Credentials
    /// A probe's failure, on a refresh response.
    public var probeError: String?
    public var quota: Quota?
    public var login: Login

    enum CodingKeys: String, CodingKey {
        case id, email, runtime, priority, status, credentials, quota, login
        case isCurrent = "is_current"
        case effectiveStatus = "effective_status"
        case quotaHitCount = "quota_hit_count"
        case apiKeyAccount = "api_key_account"
        case probeError = "probe_error"
    }

    public init(id: Int, email: String, runtime: String, priority: Int = 0, isCurrent: Bool = false, status: String = "active", effectiveStatus: String? = nil,
                quotaHitCount: Int = 0, apiKeyAccount: Bool = false, credentials: Credentials, probeError: String? = nil, quota: Quota? = nil,
                login: Login = Login(available: true)) {
        self.id = id
        self.email = email
        self.runtime = runtime
        self.priority = priority
        self.isCurrent = isCurrent
        self.status = status
        self.effectiveStatus = effectiveStatus ?? status
        self.quotaHitCount = quotaHitCount
        self.apiKeyAccount = apiKeyAccount
        self.credentials = credentials
        self.probeError = probeError
        self.quota = quota
        self.login = login
    }

    public var isCodex: Bool { runtime == InferenceReport.codex }

    /// The status badge's words (`InferenceHelper#account_status_badge_tag`).
    public var statusLabel: String {
        switch effectiveStatus {
        case "active": return "Active"
        case "quota_exceeded": return "Quota Exceeded"
        case "needs_reauth": return "Needs Reauth"
        default: return effectiveStatus.split(separator: "_").map(\.capitalized).joined(separator: " ")
        }
    }

    /// The tag on the header line about the credential itself: the badge is about quota.
    public var credentialTag: String? {
        if apiKeyAccount { return "API key" }
        if !credentials.stored { return "No tokens" }
        if credentials.refused { return "Token refused" }
        return nil
    }

    /// The sentence under the card (`InferenceHelper#credential_state_line`), with whether
    /// it is a warning.
    public func credentialLine(now: Date = Date()) -> (text: String, warning: Bool) {
        if isCodex && credentials.stored { return ("Credentials stored. Re-authenticate to replace them.", false) }
        switch credentials.state {
        case "none": return ("No credentials yet — authenticate to start serving sessions.", false)
        case "rejected":
            let ago = credentials.rejectedAt.map { InferenceFormat.ago($0, now: now) } ?? "a while ago"
            return ("Anthropic refused these credentials \(ago) — re-authenticate to replace them.", true)
        case "verified":
            let ago = credentials.verifiedAt.map { InferenceFormat.ago($0, now: now) } ?? "a while ago"
            return ("Credentials verified against Anthropic \(ago).", false)
        default: return ("Credentials stored, not yet checked against Anthropic.", true)
        }
    }

    /// The card's note in place of quota bars for a Codex account.
    public var codexNote: String? {
        guard isCodex else { return nil }
        return apiKeyAccount ? "Authenticates with a stored OpenAI API key — no usage quota tracked." : "Authenticated via OpenAI OAuth — no usage quota tracked."
    }

    /// Switch is offered to any account but the current one, and to a current Codex account
    /// as Re-activate, which rewrites its credential file from the stored copy.
    public var activateLabel: String? {
        if !isCurrent { return "Make current" }
        return isCodex ? "Re-activate" : nil
    }

    public var activateConfirmation: String {
        isCurrent ? "Re-write \(email)'s credentials to the worker?" : "Switch to \(email)?"
    }

    public var deleteConfirmation: String {
        isCurrent
            ? "\(email) is the current account. Deleting it will activate the next available account (or leave this runtime with none). Continue?"
            : "Delete \(email)?"
    }

    public var authenticateLabel: String { credentials.stored ? "Re-authenticate" : "Authenticate" }
}

/// One CLI login attempt as the card's panel renders it. The pasted authorization code is
/// never echoed; `codeReceived` says one arrived.
public struct LoginAttempt: Hashable, Sendable, Decodable, Identifiable {
    public static let terminalStatuses: Set<String> = ["succeeded", "failed", "canceled", "expired"]

    public var id: Int
    public var accountID: Int
    public var runtime: String
    /// `starting`, `awaiting_user`, `awaiting_code`, `completing`, then one of the terminal four.
    public var status: String
    public var terminal: Bool
    /// `nil` unless the caller is a person: with it, a holder of the fleet's key could finish
    /// the login with an account of its own.
    public var verificationURL: String?
    public var verificationCode: String?
    public var awaitingCode: Bool
    public var codeReceived: Bool
    public var errorMessage: String?
    public var expiresAt: Date?
    public var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, runtime, status, terminal
        case accountID = "account_id"
        case verificationURL = "verification_url"
        case verificationCode = "verification_code"
        case awaitingCode = "awaiting_code"
        case codeReceived = "code_received"
        case errorMessage = "error_message"
        case expiresAt = "expires_at"
        case createdAt = "created_at"
    }

    public init(id: Int, accountID: Int, runtime: String, status: String, verificationURL: String? = nil, verificationCode: String? = nil,
                codeReceived: Bool = false, errorMessage: String? = nil, expiresAt: Date? = nil, createdAt: Date? = nil) {
        self.id = id
        self.accountID = accountID
        self.runtime = runtime
        self.status = status
        self.terminal = Self.terminalStatuses.contains(status)
        self.verificationURL = verificationURL
        self.verificationCode = verificationCode
        self.awaitingCode = status == "awaiting_code"
        self.codeReceived = codeReceived
        self.errorMessage = errorMessage
        self.expiresAt = expiresAt
        self.createdAt = createdAt
    }

    public var succeeded: Bool { status == "succeeded" }

    /// The panel's sentence for the state (`_login_attempt.html.erb`).
    public var headline: String {
        switch status {
        case "starting": return "Starting the login CLI and waiting for a verification link…"
        case "awaiting_user": return verificationCode == nil ? "Open the link and authorize" : "Open the link and enter the one-time code"
        case "awaiting_code": return codeReceived ? "Code received — finishing sign-in…" : "Paste the authorization code the page shows"
        case "completing": return "Finishing sign-in and capturing credentials…"
        case "succeeded": return "Signed in — credentials captured"
        case "failed": return errorMessage.map { "Login failed: \($0)" } ?? "Login failed"
        case "canceled": return "Login canceled"
        case "expired": return errorMessage ?? "This login expired before completion"
        default: return status.replacingOccurrences(of: "_", with: " ").capitalized + "…"
        }
    }

    /// The link is kept through `awaiting_code`: the Claude flow prints it and blocks on its
    /// paste prompt almost at once, so `awaiting_user` is often skipped between polls.
    public var showsLink: Bool { status == "awaiting_user" || status == "awaiting_code" }
}

/// The Account Pool card and the dry-pool banner.
public struct InferencePool: Hashable, Sendable, Decodable {
    public struct Dry: Hashable, Sendable, Decodable {
        /// Why each account cannot serve, keyed by reason, with how many are in it.
        public var reasons: [String: Int]
        /// "1 refused by Anthropic, 2 out of quota".
        public var breakdown: String
        public var recovery: String

        public init(reasons: [String: Int], breakdown: String, recovery: String) {
            self.reasons = reasons
            self.breakdown = breakdown
            self.recovery = recovery
        }
    }

    public var total: Int
    public var active: Int
    public var quotaExceeded: Int
    public var needsReauth: Int
    /// The averages the spot gate decides on.
    public var fiveHourUtilization: Double?
    public var weeklyUtilization: Double?
    public var worstFiveHourUtilization: Double?
    public var worstWeeklyUtilization: Double?
    public var readCount: Int
    public var servableCount: Int
    public var weeklySpentCount: Int
    public var capacityNow: Bool
    public var nextCapacityAt: Date?
    public var nextWeeklyReset: Date?
    public var dry: Dry?

    enum CodingKeys: String, CodingKey {
        case total, active, dry
        case quotaExceeded = "quota_exceeded"
        case needsReauth = "needs_reauth"
        case fiveHourUtilization = "five_hour_utilization"
        case weeklyUtilization = "weekly_utilization"
        case worstFiveHourUtilization = "worst_five_hour_utilization"
        case worstWeeklyUtilization = "worst_weekly_utilization"
        case readCount = "read_count"
        case servableCount = "servable_count"
        case weeklySpentCount = "weekly_spent_count"
        case capacityNow = "capacity_now"
        case nextCapacityAt = "next_capacity_at"
        case nextWeeklyReset = "next_weekly_reset"
    }

    public init(total: Int, active: Int, quotaExceeded: Int, needsReauth: Int, fiveHourUtilization: Double? = nil, weeklyUtilization: Double? = nil,
                worstFiveHourUtilization: Double? = nil, worstWeeklyUtilization: Double? = nil, readCount: Int = 0, servableCount: Int = 0,
                weeklySpentCount: Int = 0, capacityNow: Bool = true, nextCapacityAt: Date? = nil, nextWeeklyReset: Date? = nil, dry: Dry? = nil) {
        self.total = total
        self.active = active
        self.quotaExceeded = quotaExceeded
        self.needsReauth = needsReauth
        self.fiveHourUtilization = fiveHourUtilization
        self.weeklyUtilization = weeklyUtilization
        self.worstFiveHourUtilization = worstFiveHourUtilization
        self.worstWeeklyUtilization = worstWeeklyUtilization
        self.readCount = readCount
        self.servableCount = servableCount
        self.weeklySpentCount = weeklySpentCount
        self.capacityNow = capacityNow
        self.nextCapacityAt = nextCapacityAt
        self.nextWeeklyReset = nextWeeklyReset
        self.dry = dry
    }
}

/// One row of the Rotation Log.
public struct RotationEvent: Hashable, Sendable, Decodable, Identifiable {
    public struct Side: Hashable, Sendable, Decodable {
        public var email: String?
        public var deleted: Bool

        public init(email: String?, deleted: Bool = false) {
            self.email = email
            self.deleted = deleted
        }

        /// A deleted account keeps its email and is labelled so; an em dash means there was
        /// no account on that side.
        public var label: String {
            guard let email else { return "—" }
            return deleted ? "\(email) (deleted)" : email
        }
    }

    public var id: Int
    public var at: Date
    public var from: Side
    public var to: Side
    public var reason: String?
    /// `automatic` or `manual`.
    public var source: String?
    public var triggeredBy: String?
    public var sessionID: Int?

    enum CodingKeys: String, CodingKey {
        case id, at, from, to, reason, source
        case triggeredBy = "triggered_by"
        case sessionID = "session_id"
    }

    public init(id: Int, at: Date, from: Side, to: Side, reason: String? = nil, source: String? = nil, triggeredBy: String? = nil, sessionID: Int? = nil) {
        self.id = id
        self.at = at
        self.from = from
        self.to = to
        self.reason = reason
        self.source = source
        self.triggeredBy = triggeredBy
        self.sessionID = sessionID
    }
}

/// The Pi tab's OpenRouter key: its state, never the key. The page sets and deletes it; the
/// app only reads.
public struct OpenRouterKeyState: Hashable, Sendable, Decodable {
    public struct LastWrite: Hashable, Sendable, Decodable {
        public var at: Date
        public var action: String

        public init(at: Date, action: String) {
            self.at = at
            self.action = action
        }
    }

    public var variable: String
    public var present: Bool
    public var providerLabel: String?
    public var providerBadge: String?
    /// A truncated SHA-256 of the value.
    public var fingerprint: String?
    public var path: String?
    public var projectID: String?
    public var location: String?
    public var lastWrite: LastWrite?
    public var writable: Bool
    public var deletable: Bool
    public var writeReason: String?
    public var missingPermissions: [String]

    enum CodingKeys: String, CodingKey {
        case variable, present, fingerprint, path, location, writable, deletable
        case providerLabel = "provider_label"
        case providerBadge = "provider_badge"
        case projectID = "project_id"
        case lastWrite = "last_write"
        case writeReason = "write_reason"
        case missingPermissions = "missing_permissions"
    }

    public init(variable: String, present: Bool, providerLabel: String? = nil, providerBadge: String? = nil, fingerprint: String? = nil, path: String? = nil,
                projectID: String? = nil, location: String? = nil, lastWrite: LastWrite? = nil, writable: Bool = false, deletable: Bool = false,
                writeReason: String? = nil, missingPermissions: [String] = []) {
        self.variable = variable
        self.present = present
        self.providerLabel = providerLabel
        self.providerBadge = providerBadge
        self.fingerprint = fingerprint
        self.path = path
        self.projectID = projectID
        self.location = location
        self.lastWrite = lastWrite
        self.writable = writable
        self.deletable = deletable
        self.writeReason = writeReason
        self.missingPermissions = missingPermissions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        variable = try container.decode(String.self, forKey: .variable)
        present = try container.decode(Bool.self, forKey: .present)
        providerLabel = try container.decodeIfPresent(String.self, forKey: .providerLabel)
        providerBadge = try container.decodeIfPresent(String.self, forKey: .providerBadge)
        fingerprint = try container.decodeIfPresent(String.self, forKey: .fingerprint)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        projectID = try container.decodeIfPresent(String.self, forKey: .projectID)
        location = try container.decodeIfPresent(String.self, forKey: .location)
        lastWrite = try container.decodeIfPresent(LastWrite.self, forKey: .lastWrite)
        writable = try container.decodeIfPresent(Bool.self, forKey: .writable) ?? false
        deletable = try container.decodeIfPresent(Bool.self, forKey: .deletable) ?? false
        writeReason = try container.decodeIfPresent(String.self, forKey: .writeReason)
        missingPermissions = try container.decodeIfPresent([String].self, forKey: .missingPermissions) ?? []
    }
}

/// The spot gate card: its six knobs, the live decision, why spot work is held and until
/// when, and the dormant populations.
public struct SpotPolicy: Hashable, Sendable, Decodable {
    public struct Decision: Hashable, Sendable, Decodable {
        public var allowed: Bool
        public var reason: String?
        public var detail: String?
        public var activeSessions: Int?
        public var awaitingSessions: Int?
        public var fleetCap: Int?

        enum CodingKeys: String, CodingKey {
            case allowed, reason, detail
            case activeSessions = "active_sessions"
            case awaitingSessions = "awaiting_sessions"
            case fleetCap = "fleet_cap"
        }

        public init(allowed: Bool, reason: String? = nil, detail: String? = nil, activeSessions: Int? = nil, awaitingSessions: Int? = nil, fleetCap: Int? = nil) {
            self.allowed = allowed
            self.reason = reason
            self.detail = detail
            self.activeSessions = activeSessions
            self.awaitingSessions = awaitingSessions
            self.fleetCap = fleetCap
        }
    }

    public struct HoldLine: Hashable, Sendable, Decodable, Identifiable {
        public var label: String
        public var sentence: String
        public var id: String { label }

        public init(label: String, sentence: String) {
            self.label = label
            self.sentence = sentence
        }
    }

    public struct Starvation: Hashable, Sendable, Decodable {
        public var ceilingHours: Int?
        public var starvedCount: Int
        public var oldestHoldAgeSeconds: Int?
        public var occupants: [String]

        enum CodingKeys: String, CodingKey {
            case occupants
            case ceilingHours = "ceiling_hours"
            case starvedCount = "starved_count"
            case oldestHoldAgeSeconds = "oldest_hold_age_seconds"
        }

        public init(ceilingHours: Int?, starvedCount: Int, oldestHoldAgeSeconds: Int? = nil, occupants: [String] = []) {
            self.ceilingHours = ceilingHours
            self.starvedCount = starvedCount
            self.oldestHoldAgeSeconds = oldestHoldAgeSeconds
            self.occupants = occupants
        }
    }

    public var gatingEnabled: Bool
    public var fiveHourReservePct: Int
    public var weeklyReservePct: Int
    public var maxConcurrentSessions: Int
    public var preemptionEnabled: Bool
    public var starvationAgeCeilingHours: Int
    public var workerSlots: Int?
    public var ceilingOutOfReach: Bool
    public var effectiveCeiling: Int?
    public var decision: Decision
    public var hold: [HoldLine]
    public var pausedCount: Int
    public var preemptedCount: Int
    public var heldCount: Int
    public var overdueHoldCount: Int
    public var sessionsAsleep: String?
    public var sessionsPreempted: String?
    public var sessionsHeld: String?
    public var sessionsStarved: String?
    public var starvation: Starvation

    enum CodingKeys: String, CodingKey {
        case decision, hold, starvation
        case gatingEnabled = "gating_enabled"
        case fiveHourReservePct = "five_hour_reserve_pct"
        case weeklyReservePct = "weekly_reserve_pct"
        case maxConcurrentSessions = "max_concurrent_sessions"
        case preemptionEnabled = "preemption_enabled"
        case starvationAgeCeilingHours = "starvation_age_ceiling_hours"
        case workerSlots = "worker_slots"
        case ceilingOutOfReach = "ceiling_out_of_reach"
        case effectiveCeiling = "effective_ceiling"
        case pausedCount = "paused_count"
        case preemptedCount = "preempted_count"
        case heldCount = "held_count"
        case overdueHoldCount = "overdue_hold_count"
        case sessionsAsleep = "sessions_asleep"
        case sessionsPreempted = "sessions_preempted"
        case sessionsHeld = "sessions_held"
        case sessionsStarved = "sessions_starved"
    }

    public init(gatingEnabled: Bool, fiveHourReservePct: Int, weeklyReservePct: Int, maxConcurrentSessions: Int, preemptionEnabled: Bool,
                starvationAgeCeilingHours: Int, workerSlots: Int? = nil, ceilingOutOfReach: Bool = false, effectiveCeiling: Int? = nil, decision: Decision,
                hold: [HoldLine] = [], pausedCount: Int = 0, preemptedCount: Int = 0, heldCount: Int = 0, overdueHoldCount: Int = 0,
                sessionsAsleep: String? = nil, sessionsPreempted: String? = nil, sessionsHeld: String? = nil, sessionsStarved: String? = nil,
                starvation: Starvation) {
        self.gatingEnabled = gatingEnabled
        self.fiveHourReservePct = fiveHourReservePct
        self.weeklyReservePct = weeklyReservePct
        self.maxConcurrentSessions = maxConcurrentSessions
        self.preemptionEnabled = preemptionEnabled
        self.starvationAgeCeilingHours = starvationAgeCeilingHours
        self.workerSlots = workerSlots
        self.ceilingOutOfReach = ceilingOutOfReach
        self.effectiveCeiling = effectiveCeiling
        self.decision = decision
        self.hold = hold
        self.pausedCount = pausedCount
        self.preemptedCount = preemptedCount
        self.heldCount = heldCount
        self.overdueHoldCount = overdueHoldCount
        self.sessionsAsleep = sessionsAsleep
        self.sessionsPreempted = sessionsPreempted
        self.sessionsHeld = sessionsHeld
        self.sessionsStarved = sessionsStarved
        self.starvation = starvation
    }

    /// The card's note when the cap sits above the worker pool.
    public var capNote: String? {
        guard ceilingOutOfReach, let slots = workerSlots, let effective = effectiveCeiling else { return nil }
        return "The agents pool runs \(slots) turns at once, so this cap of \(maxConcurrentSessions) can never be reached and spot work is never held for fleet_at_cap. The effective cap is \(effective) until that pool grows; the quota ceilings still hold spot work as before."
    }
}

/// `PATCH /api/v1/inference/spot_policy`: any subset of the six knobs, under the parameter
/// names `action_spot_policy set_gating` takes.
public struct SpotPolicyChange: Hashable, Sendable {
    public var enabled: Bool?
    public var fiveHourReservePct: Int?
    public var weeklyReservePct: Int?
    public var maxConcurrentSessions: Int?
    public var preemptionEnabled: Bool?
    public var starvationAgeCeilingHours: Int?

    public init(enabled: Bool? = nil, fiveHourReservePct: Int? = nil, weeklyReservePct: Int? = nil, maxConcurrentSessions: Int? = nil,
                preemptionEnabled: Bool? = nil, starvationAgeCeilingHours: Int? = nil) {
        self.enabled = enabled
        self.fiveHourReservePct = fiveHourReservePct
        self.weeklyReservePct = weeklyReservePct
        self.maxConcurrentSessions = maxConcurrentSessions
        self.preemptionEnabled = preemptionEnabled
        self.starvationAgeCeilingHours = starvationAgeCeilingHours
    }

    /// The whole form, as the web form posts every field.
    public init(_ policy: SpotPolicy) {
        self.init(enabled: policy.gatingEnabled, fiveHourReservePct: policy.fiveHourReservePct, weeklyReservePct: policy.weeklyReservePct,
                  maxConcurrentSessions: policy.maxConcurrentSessions, preemptionEnabled: policy.preemptionEnabled,
                  starvationAgeCeilingHours: policy.starvationAgeCeilingHours)
    }

    public var json: [String: Any] {
        var json: [String: Any] = [:]
        if let enabled { json["enabled"] = enabled }
        if let fiveHourReservePct { json["five_hour_reserve_pct"] = fiveHourReservePct }
        if let weeklyReservePct { json["weekly_reserve_pct"] = weeklyReservePct }
        if let maxConcurrentSessions { json["max_concurrent_sessions"] = maxConcurrentSessions }
        if let preemptionEnabled { json["preemption_enabled"] = preemptionEnabled }
        if let starvationAgeCeilingHours { json["starvation_age_ceiling_hours"] = starvationAgeCeilingHours }
        return json
    }

    public var isEmpty: Bool { json.isEmpty }
}

/// The backlog top-up card: the four knobs and where the fleet sits against them.
public struct FleetTopUp: Hashable, Sendable, Decodable {
    public var maxRunningSessions: Int
    public var idleMinutes: Int
    public var minFireIntervalMinutes: Int
    public var quietBacklogIntervalMinutes: Int
    /// `at_ceiling`, `clock_not_started`, `inside_threshold`, `backlog_quiet`, `cooling_down`, `due`.
    public var state: String
    public var runningSessions: Int
    public var awaitingSessions: Int
    public var asleepSessions: Int
    public var headroom: Int
    public var workerSlots: Int?
    public var ceilingOutOfReach: Bool
    public var effectiveCeiling: Int?
    public var underCeilingSince: Date?
    public var lastFiredAt: Date?
    public var nextFireAt: Date?
    public var cadence: String?
    public var quietCadence: String?
    public var sentence: String?

    enum CodingKeys: String, CodingKey {
        case state, headroom, cadence, sentence
        case maxRunningSessions = "max_running_sessions"
        case idleMinutes = "idle_minutes"
        case minFireIntervalMinutes = "min_fire_interval_minutes"
        case quietBacklogIntervalMinutes = "quiet_backlog_interval_minutes"
        case runningSessions = "running_sessions"
        case awaitingSessions = "awaiting_sessions"
        case asleepSessions = "asleep_sessions"
        case workerSlots = "worker_slots"
        case ceilingOutOfReach = "ceiling_out_of_reach"
        case effectiveCeiling = "effective_ceiling"
        case underCeilingSince = "under_ceiling_since"
        case lastFiredAt = "last_fired_at"
        case nextFireAt = "next_fire_at"
        case quietCadence = "quiet_cadence"
    }

    public init(maxRunningSessions: Int, idleMinutes: Int, minFireIntervalMinutes: Int, quietBacklogIntervalMinutes: Int, state: String,
                runningSessions: Int = 0, awaitingSessions: Int = 0, asleepSessions: Int = 0, headroom: Int = 0, workerSlots: Int? = nil,
                ceilingOutOfReach: Bool = false, effectiveCeiling: Int? = nil, underCeilingSince: Date? = nil, lastFiredAt: Date? = nil,
                nextFireAt: Date? = nil, cadence: String? = nil, quietCadence: String? = nil, sentence: String? = nil) {
        self.maxRunningSessions = maxRunningSessions
        self.idleMinutes = idleMinutes
        self.minFireIntervalMinutes = minFireIntervalMinutes
        self.quietBacklogIntervalMinutes = quietBacklogIntervalMinutes
        self.state = state
        self.runningSessions = runningSessions
        self.awaitingSessions = awaitingSessions
        self.asleepSessions = asleepSessions
        self.headroom = headroom
        self.workerSlots = workerSlots
        self.ceilingOutOfReach = ceilingOutOfReach
        self.effectiveCeiling = effectiveCeiling
        self.underCeilingSince = underCeilingSince
        self.lastFiredAt = lastFiredAt
        self.nextFireAt = nextFireAt
        self.cadence = cadence
        self.quietCadence = quietCadence
        self.sentence = sentence
    }

    public var underCeiling: Bool { state != "at_ceiling" }

    public var ceilingNote: String? {
        guard ceilingOutOfReach, let slots = workerSlots, let effective = effectiveCeiling else { return nil }
        return "The agents pool runs \(slots) turns at once, so this ceiling of \(maxRunningSessions) can never be reached: the fleet always counts as having room, and the settings beside this one are all that paces top-up. The effective ceiling is \(effective) until that pool grows."
    }

    /// "Next fire, at the earliest" as the card words it.
    public func nextFireLine(now: Date = Date()) -> String {
        guard let nextFireAt else { return "no clock running" }
        return nextFireAt <= now ? "at the next check" : "in \(InferenceFormat.duration(nextFireAt.timeIntervalSince(now)))"
    }
}

/// `PATCH /api/v1/inference/fleet_top_up`: any subset of the four knobs.
public struct FleetTopUpChange: Hashable, Sendable {
    public var maxRunningSessions: Int?
    public var idleMinutes: Int?
    public var minFireIntervalMinutes: Int?
    public var quietBacklogIntervalMinutes: Int?

    public init(maxRunningSessions: Int? = nil, idleMinutes: Int? = nil, minFireIntervalMinutes: Int? = nil, quietBacklogIntervalMinutes: Int? = nil) {
        self.maxRunningSessions = maxRunningSessions
        self.idleMinutes = idleMinutes
        self.minFireIntervalMinutes = minFireIntervalMinutes
        self.quietBacklogIntervalMinutes = quietBacklogIntervalMinutes
    }

    public var json: [String: Any] {
        var json: [String: Any] = [:]
        if let maxRunningSessions { json["max_running_sessions"] = maxRunningSessions }
        if let idleMinutes { json["idle_minutes"] = idleMinutes }
        if let minFireIntervalMinutes { json["min_fire_interval_minutes"] = minFireIntervalMinutes }
        if let quietBacklogIntervalMinutes { json["quiet_backlog_interval_minutes"] = quietBacklogIntervalMinutes }
        return json
    }

    public var isEmpty: Bool { json.isEmpty }
}

/// Every genesis kind with the class it resolves to. The page offers a button for the
/// settable kinds alone; the rest take their class from the trigger that fires them.
public struct GenesisClasses: Hashable, Sendable, Decodable {
    public struct Kind: Hashable, Sendable, Decodable, Identifiable {
        public var key: String
        public var label: String
        public var description: String?
        public var defaultClass: String
        public var priorityClass: String
        public var overridden: Bool
        public var settable: Bool
        public var liveSessions: Int
        public var id: String { key }

        enum CodingKeys: String, CodingKey {
            case key, label, description, overridden, settable
            case defaultClass = "default_class"
            case priorityClass = "class"
            case liveSessions = "live_sessions"
        }

        public init(key: String, label: String, description: String? = nil, defaultClass: String, priorityClass: String? = nil, settable: Bool = true,
                    liveSessions: Int = 0) {
            self.key = key
            self.label = label
            self.description = description
            self.defaultClass = defaultClass
            self.priorityClass = priorityClass ?? defaultClass
            self.overridden = self.priorityClass != defaultClass
            self.settable = settable
            self.liveSessions = liveSessions
        }

        /// The class a tap on the button moves the kind to.
        public var target: String { priorityClass == "priority" ? "spot" : "priority" }
    }

    public var overrides: [String: String]
    public var kinds: [Kind]

    public init(overrides: [String: String] = [:], kinds: [Kind]) {
        self.overrides = overrides
        self.kinds = kinds
    }

    public var settable: [Kind] { kinds.filter(\.settable) }
}

/// What a genesis reclassification or reset answers.
public struct GenesisClassChange: Hashable, Sendable, Decodable {
    public var message: String
    public var genesisClasses: GenesisClasses

    enum CodingKeys: String, CodingKey {
        case message
        case genesisClasses = "genesis_classes"
    }

    public init(message: String, genesisClasses: GenesisClasses) {
        self.message = message
        self.genesisClasses = genesisClasses
    }
}

/// What an account verb answers: the account as it stands, and the server's sentence.
public struct InferenceAccountChange: Hashable, Sendable, Decodable {
    public var account: InferenceAccount
    public var message: String?

    public init(account: InferenceAccount, message: String? = nil) {
        self.account = account
        self.message = message
    }
}

/// A refresh: the account with its fresh reading (or `probeError`), and the pool it moved.
public struct InferenceAccountRefresh: Hashable, Sendable, Decodable {
    public var account: InferenceAccount
    public var pool: InferencePool?

    public init(account: InferenceAccount, pool: InferencePool? = nil) {
        self.account = account
        self.pool = pool
    }
}

/// A deletion: the server's sentence and which account is current afterwards, if any.
public struct InferenceAccountRemoval: Hashable, Sendable, Decodable {
    public var message: String
    public var currentAccount: InferenceAccount?

    enum CodingKeys: String, CodingKey {
        case message
        case currentAccount = "current_account"
    }

    public init(message: String, currentAccount: InferenceAccount? = nil) {
        self.message = message
        self.currentAccount = currentAccount
    }
}

/// A login poll: the attempt, and the account's card beside it so a succeeded login shows
/// the account it authenticated.
public struct LoginPoll: Hashable, Sendable, Decodable {
    public var login: LoginAttempt
    public var account: InferenceAccount?

    public init(login: LoginAttempt, account: InferenceAccount? = nil) {
        self.login = login
        self.account = account
    }
}

/// The page's own wordings of time, where `Format.age` is too short.
public enum InferenceFormat {
    /// "2h 10m", "4d 3h", "< 1m" — `InferenceHelper#time_until_reset`.
    public static func duration(_ interval: TimeInterval) -> String {
        guard interval >= 60 else { return "< 1m" }
        let total = Int(interval)
        let days = total / 86_400
        let hours = (total % 86_400) / 3600
        let minutes = (total % 3600) / 60
        var parts: [String] = []
        if days > 0 { parts.append("\(days)d") }
        if hours > 0 { parts.append("\(hours)h") }
        if minutes > 0 { parts.append("\(minutes)m") }
        return parts.joined(separator: " ")
    }

    /// "3 days ago", "41 minutes ago", "just now" — Rails' `time_ago_in_words`, near enough.
    public static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        func plural(_ count: Int, _ unit: String) -> String { "\(count) \(unit)\(count == 1 ? "" : "s") ago" }
        switch seconds {
        case ..<60: return "less than a minute ago"
        case ..<3600: return plural(Int(seconds / 60), "minute")
        case ..<86_400: return plural(Int(seconds / 3600), "hour")
        case ..<(86_400 * 30): return plural(Int(seconds / 86_400), "day")
        default: return plural(Int(seconds / (86_400 * 30)), "month")
        }
    }
}
