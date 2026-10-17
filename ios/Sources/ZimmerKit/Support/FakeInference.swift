import Foundation

/// The fake's Inference page: a Claude Code pool of three accounts (one current, one out of
/// quota, one whose probe fails), a Codex pool of two, the Pi tab's key state, the rotation
/// log, and the policy. A login attempt walks through its states on successive polls, as the
/// worker drives the CLI on the server.
struct FakeInference: Sendable {
    static let actor = "tadas@tadasant.com via the iOS app"
    static let relayRefusal = "This sign-in may not act as you; sign in again and allow acting as you"

    var accounts: [InferenceAccount]
    var attempts: [LoginAttempt] = []
    /// How many times each attempt has been polled: what moves it along.
    var polls: [Int: Int] = [:]
    var rotations: [RotationEvent]
    var spotPolicy: SpotPolicy
    var fleetTopUp: FleetTopUp
    var genesis: GenesisClasses
    var openrouter: OpenRouterKeyState
    var nextAccountID = 20
    var nextAttemptID = 300
    var nextRotationID = 70

    init(now: Date) {
        func hours(_ count: Double) -> Date { now.addingTimeInterval(count * 3600) }
        let ops = InferenceAccount(
            id: 11, email: "ops@tadasant.com", runtime: InferenceReport.claudeCode, priority: 0, isCurrent: true, status: "active", quotaHitCount: 2,
            credentials: .init(state: "verified", stored: true, verifiedAt: hours(-72)),
            quota: .init(takenAt: hours(-0.25), trigger: "rotation_check", subscriptionType: "max", rateLimitTier: "default_claude_max_20x",
                         fiveHour: .init(utilization: 0.42, status: "allowed", resetAt: hours(2.17)),
                         sevenDay: .init(utilization: 0.63, status: "allowed", resetAt: hours(99))),
            login: .init(available: true, lastAttempt: .init(id: 201, status: "succeeded"))
        )
        let spot = InferenceAccount(
            id: 12, email: "spot@tadasant.com", runtime: InferenceReport.claudeCode, priority: 1, status: "quota_exceeded", quotaHitCount: 7,
            credentials: .init(state: "verified", stored: true, verifiedAt: hours(-30)),
            quota: .init(takenAt: hours(-0.5), trigger: "manual_refresh", subscriptionType: "max", rateLimitTier: "default_claude_max_5x",
                         fiveHour: .init(utilization: 0.31, status: "allowed", resetAt: hours(1.08)),
                         sevenDay: .init(utilization: 1.0, status: "rejected", resetAt: hours(50)),
                         fiveHourHeadroomUnusable: true)
        )
        // Its last probe failed, and the card wears that until a refresh succeeds. The server
        // carries `probe_error` on a refresh response only; the fake keeps the last one.
        let backup = InferenceAccount(
            id: 13, email: "backup@tadasant.com", runtime: InferenceReport.claudeCode, priority: 2, status: "active", quotaHitCount: 0,
            credentials: .init(state: "rejected", stored: true, refused: true, rejectedAt: hours(-5),
                               rejectionReason: "Anthropic answered 401 Unauthorized to the usage probe"),
            probeError: "Anthropic answered 401 Unauthorized: the stored access token was refused",
            quota: .init(takenAt: hours(-26), trigger: "manual_refresh", subscriptionType: "pro", rateLimitTier: "default_claude_pro",
                         fiveHour: .init(utilization: 0.88, status: "allowed", resetAt: hours(-21), resetPassed: true),
                         sevenDay: .init(utilization: 0.12, status: "allowed", resetAt: hours(120))),
            login: .init(available: true, lastAttempt: .init(id: 204, status: "failed", errorMessage: "The CLI exited before printing a verification link"))
        )
        let codexKey = InferenceAccount(
            id: 14, email: "codex-ops@tadasant.com", runtime: InferenceReport.codex, priority: 0, isCurrent: true, status: "active", apiKeyAccount: true,
            credentials: .init(state: "unverified", stored: true), login: .init(available: false)
        )
        let codexOAuth = InferenceAccount(
            id: 15, email: "codex-backup@tadasant.com", runtime: InferenceReport.codex, priority: 1, status: "needs_reauth",
            credentials: .init(state: "none", stored: false)
        )
        accounts = [ops, spot, backup, codexKey, codexOAuth]
        // The Codex OAuth account has a login in flight, as the page shows one: the CLI has
        // printed its link and one-time code and is waiting for the approval.
        attempts = [LoginAttempt(id: 299, accountID: 15, runtime: InferenceReport.codex, status: "awaiting_user",
                                 verificationURL: "https://auth.openai.com/codex/device", verificationCode: "WXYZ-7K2Q",
                                 expiresAt: now.addingTimeInterval(540), createdAt: now.addingTimeInterval(-60))]
        rotations = [
            RotationEvent(id: 61, at: hours(-0.6), from: .init(email: "spot@tadasant.com"), to: .init(email: "ops@tadasant.com"),
                          reason: "quota_exceeded", source: "automatic", triggeredBy: "session:1042", sessionID: 1042),
            RotationEvent(id: 60, at: hours(-9), from: .init(email: "ops@tadasant.com"), to: .init(email: "spot@tadasant.com"),
                          reason: "manual_switch", source: "manual", triggeredBy: "tadas@tadasant.com"),
            RotationEvent(id: 58, at: hours(-80), from: .init(email: "old@tadasant.com", deleted: true), to: .init(email: "ops@tadasant.com"),
                          reason: "account_deleted", source: "automatic", triggeredBy: "tadas@tadasant.com"),
        ]
        spotPolicy = SpotPolicy(
            gatingEnabled: true, fiveHourReservePct: 15, weeklyReservePct: 20, maxConcurrentSessions: 4, preemptionEnabled: true,
            starvationAgeCeilingHours: 2, workerSlots: 4,
            decision: .init(allowed: false, reason: "five_hour_pace",
                            detail: "The 5-hour window is at 91% of its spot budget, ahead of the curve at 78%; the next spot turn waits for the curve.",
                            activeSessions: 3, awaitingSessions: 1, fleetCap: 4),
            hold: [.init(label: "Why it's held", sentence: "The 5-hour window is ahead of its pacing curve."),
                   .init(label: "Held until", sentence: "The curve catches up in about 40 minutes, or the window resets in 2h 10m.")],
            pausedCount: 1, preemptedCount: 0, heldCount: 1, overdueHoldCount: 0,
            sessionsAsleep: "1 session was paused mid-run when the pool crossed its ceiling; it resumes when the window has room.",
            sessionsPreempted: "None.",
            sessionsHeld: "1 session has been refused a turn and is checked again every 10 minutes.",
            sessionsStarved: "None past the ceiling; the lane is free.",
            starvation: .init(ceilingHours: 2, starvedCount: 0, oldestHoldAgeSeconds: 1_200)
        )
        fleetTopUp = FleetTopUp(
            maxRunningSessions: 12, idleMinutes: 5, minFireIntervalMinutes: 30, quietBacklogIntervalMinutes: 240, state: "inside_threshold",
            runningSessions: 3, awaitingSessions: 1, asleepSessions: 2, headroom: 9, workerSlots: 4, ceilingOutOfReach: true, effectiveCeiling: 4,
            underCeilingSince: hours(-0.05), lastFiredAt: hours(-3), nextFireAt: hours(0.03),
            cadence: "at most 48 times a day", quietCadence: "at most 6 times a day",
            sentence: "The fleet has 3 on a worker (1 more waiting for a slot), under its ceiling of 12 for 3 minutes; it fires once it has been under for 5."
        )
        genesis = Self.sampleGenesis()
        openrouter = OpenRouterKeyState(
            variable: "OPENROUTER_API_KEY", present: true, providerLabel: "Google Cloud Parameter Manager", providerBadge: "Parameter Store",
            fingerprint: "sha256:3f9ac2d1e7b4", path: "projects/zimmer-prod/locations/global/parameters/openrouter-api-key",
            projectID: "zimmer-prod", location: "global", lastWrite: .init(at: hours(-200), action: "set"), writable: true, deletable: true
        )
    }

    static func sampleGenesis(overrides: [String: String] = [:]) -> GenesisClasses {
        let kinds: [(String, String, String, String, Bool, Int)] = [
            ("web_ui", "Zimmer web app", "priority", "A human typed it into the Zimmer web app — the new-session form, the dashboard quick prompt, the chat bubble, the Invoke button on a trigger — or into the Zimmer browser extension on some other page.", true, 6),
            ("slack", "Slack trigger", "priority", "A Slack trigger fired on a DM or a channel message. There is a human on the other end waiting for an answer.", false, 2),
            ("email", "Email trigger", "spot", "An email trigger fired on new mail in a watched mailbox.", false, 0),
            ("github_issue", "GitHub issue trigger", "spot", "A github_issue trigger fired on a newly filed issue: automated triage nobody is waiting on.", false, 3),
            ("schedule", "Scheduled trigger", "spot", "A cron-scheduled trigger fired. Recurring automation by definition runs again, so a deferred run costs little.", false, 1),
            ("api", "API / agent spawn", "spot", "Created over the REST API, MCP start_session or MCP quick_router with no parent session to inherit from, or a trigger fired by hand over the API or MCP — so nothing connects it to a human.", true, 4),
            ("unknown", "Unknown", "priority", "Origin could not be established — chiefly rows created before genesis was recorded. Classified priority on purpose: a session Zimmer cannot explain is never one it throttles.", true, 0),
        ]
        return GenesisClasses(overrides: overrides, kinds: kinds.map { key, label, defaultClass, description, settable, live in
            GenesisClasses.Kind(key: key, label: label, description: description, defaultClass: defaultClass, priorityClass: overrides[key], settable: settable,
                                liveSessions: live)
        })
    }

    func pool(_ runtime: String) -> InferencePool {
        let roster = accounts.filter { $0.runtime == runtime }
        let readings = roster.compactMap(\.quota)
        func average(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
        let servable = roster.filter { $0.credentials.stored && !$0.credentials.refused && $0.effectiveStatus == "active" }
        var dry: InferencePool.Dry?
        if !roster.isEmpty, servable.isEmpty {
            var reasons: [String: Int] = [:]
            for account in roster {
                let reason = !account.credentials.stored ? "no_credentials" : account.status == "needs_reauth" ? "needs_reauth"
                    : account.credentials.refused ? "refused" : account.effectiveStatus == "quota_exceeded" ? "quota_exceeded" : "other"
                reasons[reason, default: 0] += 1
            }
            let labels = ["refused": "refused by Anthropic", "needs_reauth": "waiting on re-authentication", "no_credentials": "never authenticated",
                          "quota_exceeded": "out of quota", "other": "unavailable"]
            let breakdown = ["refused", "needs_reauth", "no_credentials", "quota_exceeded", "other"].compactMap { key in
                reasons[key].map { "\($0) \(labels[key]!)" }
            }.joined(separator: ", ")
            let recovery = Set(reasons.keys) == ["quota_exceeded"]
                ? "Sessions will park and resume on their own when a window resets."
                : "Sessions will park until an account recovers. Authenticate one below — a stored credential Anthropic refuses cannot be repaired by switching to it."
            dry = .init(reasons: reasons, breakdown: breakdown, recovery: recovery)
        }
        return InferencePool(
            total: roster.count, active: roster.filter { $0.effectiveStatus == "active" }.count,
            quotaExceeded: roster.filter { $0.effectiveStatus == "quota_exceeded" }.count,
            needsReauth: roster.filter { $0.effectiveStatus == "needs_reauth" }.count,
            fiveHourUtilization: average(readings.filter { !$0.fiveHourHeadroomUnusable }.compactMap { $0.fiveHour.effectiveUtilization }),
            weeklyUtilization: average(readings.compactMap { $0.sevenDay.effectiveUtilization }),
            worstFiveHourUtilization: readings.compactMap { $0.fiveHour.effectiveUtilization }.max(),
            worstWeeklyUtilization: readings.compactMap { $0.sevenDay.effectiveUtilization }.max(),
            readCount: readings.count, servableCount: servable.count, weeklySpentCount: readings.filter { $0.fiveHourHeadroomUnusable }.count,
            capacityNow: !servable.isEmpty, nextWeeklyReset: readings.filter { $0.fiveHourHeadroomUnusable }.compactMap { $0.sevenDay.resetAt }.min(),
            dry: dry
        )
    }
}

// MARK: - The Inference page
//
// As the server: every write needs a person, the current account hands over on deletion,
// a policy out of range is refused with the model's message and nothing persists.
extension FakeZimmerAPI {
    public func inference(runtime: String) async throws -> InferenceReport {
        let runtime = InferenceReport.defaultRuntimes.contains(where: { $0.key == runtime }) ? runtime : InferenceReport.claudeCode
        let isPi = runtime == InferenceReport.pi
        let roster = inference.accounts.filter { $0.runtime == runtime }.sorted { $0.priority < $1.priority }.map(card)
        return InferenceReport(
            runtime: runtime, accounts: isPi ? nil : roster, pool: isPi ? nil : inference.pool(runtime),
            rotationLog: isPi ? nil : inference.rotations, openrouterKey: isPi ? inference.openrouter : nil,
            spotPolicy: inference.spotPolicy, fleetTopUp: inference.fleetTopUp, genesisClasses: inference.genesis
        )
    }

    public func addInferenceAccount(runtime: String, email: String, priority: Int, apiKey: String?) async throws -> InferenceAccountChange {
        try requirePerson()
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { throw ZimmerError.http(status: 422, message: "Email is required to add an account.") }
        let label = InferenceReport.defaultRuntimes.first(where: { $0.key == runtime })?.label ?? runtime
        guard !inference.accounts.contains(where: { $0.runtime == runtime && $0.email.lowercased() == email.lowercased() }) else {
            throw ZimmerError.http(status: 422, message: "An account for \(email) already exists in the \(label) pool.")
        }
        let keyed = runtime == InferenceReport.codex && !(apiKey ?? "").isEmpty
        let account = InferenceAccount(
            id: inference.nextAccountID, email: email, runtime: runtime, priority: priority,
            isCurrent: keyed && !inference.accounts.contains(where: { $0.runtime == runtime && $0.isCurrent }),
            status: keyed ? "active" : "needs_reauth", apiKeyAccount: keyed,
            credentials: .init(state: keyed ? "unverified" : "none", stored: keyed), login: .init(available: !keyed)
        )
        inference.nextAccountID += 1
        inference.accounts.append(account)
        return InferenceAccountChange(account: card(account), message: keyed ? "Added \(email)." : "Added \(email). Authenticate it to capture credentials.")
    }

    public func refreshInferenceAccount(_ id: Int) async throws -> InferenceAccountRefresh {
        try requirePerson()
        let index = try accountIndex(id)
        var account = inference.accounts[index]
        if account.credentials.refused {
            account.probeError = "Anthropic answered 401 Unauthorized: the stored access token was refused"
        } else if var quota = account.quota {
            // A fresh reading: a little more spent, taken just now.
            quota.takenAt = Date()
            quota.fiveHour.utilization = min((quota.fiveHour.utilization ?? 0) + 0.03, 1)
            quota.fiveHour.effectiveUtilization = quota.fiveHour.utilization
            quota.sevenDay.utilization = min((quota.sevenDay.utilization ?? 0) + 0.01, 1)
            quota.sevenDay.effectiveUtilization = quota.sevenDay.utilization
            account.quota = quota
            account.probeError = nil
        }
        inference.accounts[index] = account
        return InferenceAccountRefresh(account: card(account), pool: inference.pool(account.runtime))
    }

    public func activateInferenceAccount(_ id: Int) async throws -> InferenceAccountChange {
        try requirePerson()
        let index = try accountIndex(id)
        let account = inference.accounts[index]
        guard account.credentials.stored else {
            throw ZimmerError.http(status: 422, message: "\(account.email) has no credentials stored. Authenticate it before switching to it.")
        }
        guard !account.credentials.refused else {
            throw ZimmerError.http(status: 422, message: "Anthropic refuses \(account.email)'s stored token. Re-authenticate it before switching to it.")
        }
        let current = inference.accounts.first { $0.runtime == account.runtime && $0.isCurrent }
        if current?.id == account.id {
            return InferenceAccountChange(account: card(account), message: "Re-activated \(account.email).")
        }
        for i in inference.accounts.indices where inference.accounts[i].runtime == account.runtime {
            inference.accounts[i].isCurrent = inference.accounts[i].id == id
        }
        inference.rotations.insert(RotationEvent(id: inference.nextRotationID, at: Date(), from: .init(email: current?.email), to: .init(email: account.email),
                                                 reason: "manual_switch", source: "manual", triggeredBy: FakeInference.actor), at: 0)
        inference.nextRotationID += 1
        return InferenceAccountChange(account: card(inference.accounts[index]), message: "Switched to \(account.email)")
    }

    public func deleteInferenceAccount(_ id: Int) async throws -> InferenceAccountRemoval {
        try requirePerson()
        let index = try accountIndex(id)
        let account = inference.accounts.remove(at: index)
        guard account.isCurrent else {
            return InferenceAccountRemoval(message: "Deleted \(account.email).", currentAccount: inference.accounts.first { $0.runtime == account.runtime && $0.isCurrent }.map(card))
        }
        let next = inference.accounts.filter { $0.runtime == account.runtime && $0.credentials.stored && !$0.credentials.refused }.min { $0.priority < $1.priority }
        guard let next, let nextIndex = inference.accounts.firstIndex(where: { $0.id == next.id }) else {
            return InferenceAccountRemoval(message: "Deleted \(account.email). No other configured account remains — this runtime now has no active account.")
        }
        inference.accounts[nextIndex].isCurrent = true
        inference.rotations.insert(RotationEvent(id: inference.nextRotationID, at: Date(), from: .init(email: account.email, deleted: true), to: .init(email: next.email),
                                                 reason: "account_deleted", source: "automatic", triggeredBy: FakeInference.actor), at: 0)
        inference.nextRotationID += 1
        return InferenceAccountRemoval(message: "Deleted \(account.email). Activated \(next.email) as the current account.",
                                       currentAccount: card(inference.accounts[nextIndex]))
    }

    public func startInferenceLogin(accountID: Int) async throws -> LoginAttempt {
        try requirePerson()
        let account = inference.accounts[try accountIndex(accountID)]
        guard !account.apiKeyAccount else { throw ZimmerError.http(status: 422, message: "API-key accounts don't use the login flow.") }
        // Starting again supersedes the attempt in flight.
        for i in inference.attempts.indices where inference.attempts[i].accountID == accountID && !inference.attempts[i].terminal {
            inference.attempts[i] = moved(inference.attempts[i], to: "canceled")
        }
        let attempt = LoginAttempt(id: inference.nextAttemptID, accountID: accountID, runtime: account.runtime, status: "starting",
                                   expiresAt: Date().addingTimeInterval(600), createdAt: Date())
        inference.nextAttemptID += 1
        inference.attempts.append(attempt)
        return attempt
    }

    public func inferenceLogin(_ id: Int) async throws -> LoginPoll {
        try requirePerson()
        guard let index = inference.attempts.firstIndex(where: { $0.id == id }) else {
            throw ZimmerError.http(status: 404, message: "Login no longer tracked: the attempt was pruned or its account was deleted")
        }
        var attempt = inference.attempts[index]
        guard let accountIndex = inference.accounts.firstIndex(where: { $0.id == attempt.accountID }) else {
            throw ZimmerError.http(status: 404, message: "Login no longer tracked: the attempt was pruned or its account was deleted")
        }
        let polls = inference.polls[id, default: 0] + 1
        inference.polls[id] = polls
        if !attempt.terminal {
            attempt = advanced(attempt, polls: polls)
            inference.attempts[index] = attempt
            if attempt.succeeded { captureCredentials(at: accountIndex) }
        }
        return LoginPoll(login: attempt, account: card(inference.accounts[accountIndex]))
    }

    public func submitInferenceLoginCode(_ id: Int, code: String) async throws -> LoginAttempt {
        try requirePerson()
        guard let index = inference.attempts.firstIndex(where: { $0.id == id }) else {
            throw ZimmerError.http(status: 404, message: "Login no longer tracked: the attempt was pruned or its account was deleted")
        }
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ZimmerError.http(status: 422, message: "Paste the authorization code the page shows")
        }
        let attempt = inference.attempts[index]
        guard !attempt.terminal else { throw ZimmerError.http(status: 422, message: "This login has already finished (\(attempt.status))") }
        inference.attempts[index].codeReceived = true
        return inference.attempts[index]
    }

    public func cancelInferenceLogin(_ id: Int) async throws -> LoginAttempt {
        try requirePerson()
        guard let index = inference.attempts.firstIndex(where: { $0.id == id }) else {
            throw ZimmerError.http(status: 404, message: "Login no longer tracked: the attempt was pruned or its account was deleted")
        }
        if !inference.attempts[index].terminal { inference.attempts[index] = moved(inference.attempts[index], to: "canceled") }
        return inference.attempts[index]
    }

    public func updateSpotPolicy(_ change: SpotPolicyChange) async throws -> SpotPolicy {
        try requirePerson()
        guard !change.isEmpty else {
            throw ZimmerError.http(status: 422, message: "Pass enabled, five_hour_reserve_pct, weekly_reserve_pct, max_concurrent_sessions, preemption_enabled, starvation_age_ceiling_hours")
        }
        var policy = inference.spotPolicy
        if let enabled = change.enabled { policy.gatingEnabled = enabled }
        if let pct = change.fiveHourReservePct { policy.fiveHourReservePct = pct }
        if let pct = change.weeklyReservePct { policy.weeklyReservePct = pct }
        if let cap = change.maxConcurrentSessions { policy.maxConcurrentSessions = cap }
        if let preemption = change.preemptionEnabled { policy.preemptionEnabled = preemption }
        if let hours = change.starvationAgeCeilingHours { policy.starvationAgeCeilingHours = hours }
        let faults = [
            Self.bound("Spot reserve five hour pct", policy.fiveHourReservePct, 0...100),
            Self.bound("Spot reserve weekly pct", policy.weeklyReservePct, 0...100),
            Self.bound("Spot max concurrent sessions", policy.maxConcurrentSessions, 1...100),
            Self.bound("Spot starvation age ceiling hours", policy.starvationAgeCeilingHours, 0...720),
        ].compactMap { $0 }
        guard faults.isEmpty else { throw ZimmerError.http(status: 422, message: faults.joined(separator: ", ")) }
        policy.ceilingOutOfReach = policy.maxConcurrentSessions > (policy.workerSlots ?? 4)
        policy.effectiveCeiling = min(policy.maxConcurrentSessions, policy.workerSlots ?? 4)
        inference.spotPolicy = policy
        return policy
    }

    public func updateFleetTopUp(_ change: FleetTopUpChange) async throws -> FleetTopUp {
        try requirePerson()
        guard !change.isEmpty else {
            throw ZimmerError.http(status: 422, message: "Pass max_running_sessions, idle_minutes, min_fire_interval_minutes, quiet_backlog_interval_minutes")
        }
        var policy = inference.fleetTopUp
        if let cap = change.maxRunningSessions { policy.maxRunningSessions = cap }
        if let minutes = change.idleMinutes { policy.idleMinutes = minutes }
        if let minutes = change.minFireIntervalMinutes { policy.minFireIntervalMinutes = minutes }
        if let minutes = change.quietBacklogIntervalMinutes { policy.quietBacklogIntervalMinutes = minutes }
        let faults = [
            Self.bound("Fleet idle max sessions", policy.maxRunningSessions, 1...100),
            Self.bound("Fleet idle threshold minutes", policy.idleMinutes, 1...1440),
            Self.bound("Fleet idle min fire interval minutes", policy.minFireIntervalMinutes, 1...10_080),
            Self.bound("Fleet idle quiet backlog interval minutes", policy.quietBacklogIntervalMinutes, 1...10_080),
        ].compactMap { $0 }
        guard faults.isEmpty else { throw ZimmerError.http(status: 422, message: faults.joined(separator: ", ")) }
        policy.ceilingOutOfReach = policy.maxRunningSessions > (policy.workerSlots ?? 4)
        policy.effectiveCeiling = min(policy.maxRunningSessions, policy.workerSlots ?? 4)
        policy.headroom = max(policy.maxRunningSessions - policy.runningSessions, 0)
        inference.fleetTopUp = policy
        return policy
    }

    public func setGenesisClass(_ genesis: String, to priorityClass: String) async throws -> GenesisClassChange {
        try requirePerson()
        guard let kind = inference.genesis.kinds.first(where: { $0.key == genesis }) else {
            throw ZimmerError.http(status: 422, message: "\"\(genesis)\" is not a genesis. Valid: web_ui, api, unknown")
        }
        guard kind.settable else {
            throw ZimmerError.http(status: 422, message: "\(kind.label) takes its class from the trigger that fires it. Set it on the trigger instead.")
        }
        guard ["spot", "priority"].contains(priorityClass) else {
            throw ZimmerError.http(status: 422, message: "priority_class must be one of spot, priority")
        }
        var overrides = inference.genesis.overrides
        if priorityClass == kind.defaultClass { overrides[genesis] = nil } else { overrides[genesis] = priorityClass }
        inference.genesis = FakeInference.sampleGenesis(overrides: overrides)
        let affected = kind.liveSessions
        return GenesisClassChange(message: "\(kind.label) is now \(priorityClass). \(affected) live session\(affected == 1 ? "" : "s") reclassified.",
                                  genesisClasses: inference.genesis)
    }

    public func resetGenesisClasses() async throws -> GenesisClassChange {
        try requirePerson()
        inference.genesis = FakeInference.sampleGenesis()
        return GenesisClassChange(message: "Genesis classes reset to defaults.", genesisClasses: inference.genesis)
    }

    // MARK: - Plumbing

    private func requirePerson() throws {
        if relayOnly { throw ZimmerError.http(status: 403, message: FakeInference.relayRefusal) }
    }

    private func accountIndex(_ id: Int) throws -> Int {
        guard let index = inference.accounts.firstIndex(where: { $0.id == id }) else {
            throw ZimmerError.http(status: 404, message: "The requested resource was not found")
        }
        return index
    }

    /// The account as its card renders it: with its login in flight, and that login's link
    /// and code only for a person.
    private func card(_ account: InferenceAccount) -> InferenceAccount {
        var account = account
        account.effectiveStatus = account.quota?.sevenDay.effectiveUtilization == 1 || account.quota?.fiveHour.effectiveUtilization == 1 ? "quota_exceeded" : account.status
        if account.login.available {
            let own = inference.attempts.filter { $0.accountID == account.id }
            account.login.activeAttempt = own.last(where: { !$0.terminal }).map(withheld)
            if let last = own.last { account.login.lastAttempt = .init(id: last.id, status: last.status, errorMessage: last.errorMessage) }
        }
        return account
    }

    private func withheld(_ attempt: LoginAttempt) -> LoginAttempt {
        guard relayOnly else { return attempt }
        var attempt = attempt
        attempt.verificationURL = nil
        attempt.verificationCode = nil
        return attempt
    }

    private func moved(_ attempt: LoginAttempt, to status: String) -> LoginAttempt {
        var attempt = attempt
        attempt.status = status
        attempt.terminal = LoginAttempt.terminalStatuses.contains(status)
        attempt.awaitingCode = status == "awaiting_code"
        return attempt
    }

    /// Where the CLI has got to after `polls` reads. Codex prints a link and a one-time code
    /// and finishes on its own once approved; Claude prints a link, then blocks on the code
    /// pasted back, and finishes once it has one.
    private func advanced(_ attempt: LoginAttempt, polls: Int) -> LoginAttempt {
        var next = attempt
        if attempt.runtime == InferenceReport.codex {
            // The code stays up for five polls — ten seconds at the sheet's cadence — so a test
            // on a loaded simulator reads and copies it, and the photograph's six-second settle
            // lands on it, before the CLI moves on.
            switch polls {
            case 1...5:
                next = moved(attempt, to: "awaiting_user")
                next.verificationURL = "https://auth.openai.com/codex/device"
                next.verificationCode = "WXYZ-7K2Q"
            case 6: next = moved(attempt, to: "completing")
            default: next = moved(attempt, to: "succeeded")
            }
        } else {
            next.verificationURL = "https://claude.ai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e"
            if attempt.codeReceived {
                next = moved(next, to: attempt.status == "completing" ? "succeeded" : "completing")
            } else {
                next = moved(next, to: polls == 1 ? "awaiting_user" : "awaiting_code")
            }
        }
        return next
    }

    private func captureCredentials(at index: Int) {
        var account = inference.accounts[index]
        let claude = account.runtime == InferenceReport.claudeCode
        account.credentials = .init(state: claude ? "verified" : "unverified", stored: true, verifiedAt: claude ? Date() : nil)
        account.status = "active"
        account.probeError = nil
        inference.accounts[index] = account
    }

    private static func bound(_ name: String, _ value: Int, _ range: ClosedRange<Int>) -> String? {
        if value < range.lowerBound { return "\(name) must be greater than or equal to \(range.lowerBound)" }
        if value > range.upperBound { return "\(name) must be less than or equal to \(range.upperBound)" }
        return nil
    }
}
