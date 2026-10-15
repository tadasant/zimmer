import Foundation

// MARK: - The operator actions, as the server answers and refuses them
//
// Each changes the state the health report, the Costs coverage banner or the CLI status is
// built from, so a screen that reads again after an action sees what the server's would.
extension FakeZimmerAPI {
    /// `HealthActionCooldown::COOLDOWN`: one cleanup, retry or trash per thirty seconds.
    static let cooldownSeconds: TimeInterval = 30

    private func cooledDown(_ action: String) throws {
        if let last = healthState.lastActions[action], Date().timeIntervalSince(last) < Self.cooldownSeconds {
            throw ZimmerError.http(status: 429, message: "Please wait \(Int(Self.cooldownSeconds)) seconds between actions")
        }
        healthState.lastActions[action] = Date()
    }

    public func cleanupProcesses() async throws -> ProcessCleanup {
        try cooledDown("cleanup_processes")
        let ended = healthState.orphanPIDs
        healthState.orphanPIDs = []
        return ProcessCleanup(terminated: ended)
    }

    public func retryFailedSessions() async throws -> SessionRetry {
        try cooledDown("retry_sessions")
        let ids = healthState.failedSessionIDs
        healthState.failedSessionIDs = []
        for id in ids { if let index = all.firstIndex(where: { $0.id == id }) { all[index].status = .waiting } }
        return SessionRetry(retried: ids)
    }

    public func archiveOldSessions(days: Int) async throws -> SessionArchive {
        try cooledDown("archive_old")
        let cutoff = Date().addingTimeInterval(-Double(min(max(days, 1), 365)) * 86_400)
        // Untouched for the window, and not a session the board still needs — the server's
        // sweep skips running and archived ones the same way.
        let stale = all.filter { $0.status != .archived && $0.status != .running && ($0.updatedAt ?? $0.createdAt ?? Date()) < cutoff }.map(\.id)
            .filter { !healthState.archivedOld.contains($0) }
        for id in stale { if let index = all.firstIndex(where: { $0.id == id }) { all[index].status = .archived } }
        healthState.archivedOld += stale
        return SessionArchive(archived: stale)
    }

    public func enterQueueRecoveryMode(reason: String?, ttlMinutes: Int?) async throws -> HealthReport.QueueRecovery {
        let minutes = clampedRecoveryTTL(ttlMinutes ?? HealthReport.QueueRecovery.defaultTTLMinutes)
        let now = Date()
        // Entering while on is an extension: the timer restarts, the entry stands.
        if !healthState.recoveryActive {
            healthState.recoveryActive = true
            healthState.recoveryEnteredAt = now
            healthState.recoveryEnteredBy = "the iOS app (tadas@example.com)"
        }
        healthState.recoveryExpiresAt = now.addingTimeInterval(Double(minutes) * 60)
        if let reason, !reason.isEmpty { healthState.recoveryReason = reason }
        return HealthReport.queueRecovery(JSONObject(Self.queueRecoveryJSON(now: now, state: healthState)))
    }

    public func exitQueueRecoveryMode() async throws -> HealthReport.QueueRecovery {
        healthState.recoveryActive = false
        healthState.recoveryEnteredAt = nil
        healthState.recoveryExpiresAt = nil
        healthState.recoveryReason = nil
        healthState.recoveryEnteredBy = nil
        return HealthReport.queueRecovery(JSONObject(Self.queueRecoveryJSON(now: Date(), state: healthState)))
    }

    /// The expiry job: a halt whose window has passed is lifted before the report is read.
    func expireRecovery() {
        if healthState.recoveryActive, let expires = healthState.recoveryExpiresAt, expires <= Date() {
            healthState.recoveryActive = false
        }
    }

    public func runPostDeployTasks() async throws -> PostDeployRearm {
        let rearmed = healthState.postDeployRearmed ? 0 : 1
        healthState.postDeployRearmed = true
        return PostDeployRearm(rearmed: rearmed, enqueued: true, pending: 1, failed: 0)
    }

    private func queuedRows(_ scope: QueuedJobScope) throws -> [(jobClass: String, queue: String, count: Int)] {
        guard scope.jobClass != nil || scope.queueName != nil else {
            throw ZimmerError.http(status: 422, message: "Refusing an unscoped job maintenance call: name a job_class, a queue_name, or both.")
        }
        if scope.queueName == "agents" || scope.jobClass == "AgentSessionJob" {
            throw ZimmerError.http(status: 422, message: "Refusing to touch \(scope.label): an unfinished job there is a live session.")
        }
        return healthState.queuedJobs.filter { row in
            (scope.jobClass == nil || scope.jobClass == row.jobClass) && (scope.queueName == nil || scope.queueName == row.queue)
        }
    }

    public func queuedJobs(_ scope: QueuedJobScope) async throws -> QueuedJobPreview {
        let rows = try queuedRows(scope)
        return QueuedJobPreview(scope: scope, matched: rows.reduce(0) { $0 + $1.count },
                                byJobClass: rows.map { HealthReport.Count($0.jobClass, $0.count) },
                                byQueue: rows.map { HealthReport.Count($0.queue, $0.count) }, maxPerCall: 2_000)
    }

    private func apply(_ action: String, _ scope: QueuedJobScope, expectedCount: Int, scheduledAt: Date?) throws -> QueuedJobReceipt {
        let rows = try queuedRows(scope)
        let matched = rows.reduce(0) { $0 + $1.count }
        guard matched == expectedCount else {
            throw ZimmerError.http(status: 422, message: "Expected \(expectedCount) queued jobs in scope, found \(matched); nothing was changed. Reload and try again.")
        }
        if action == "discard" {
            healthState.queuedJobs.removeAll { row in rows.contains { $0.jobClass == row.jobClass && $0.queue == row.queue } }
        }
        return QueuedJobReceipt(action: action, scope: scope, matched: matched, affected: matched,
                                byJobClass: rows.map { HealthReport.Count($0.jobClass, $0.count) },
                                byQueue: rows.map { HealthReport.Count($0.queue, $0.count) }, scheduledAt: scheduledAt)
    }

    public func discardQueuedJobs(_ scope: QueuedJobScope, expectedCount: Int, reason: String?) async throws -> QueuedJobReceipt {
        try apply("discard", scope, expectedCount: expectedCount, scheduledAt: nil)
    }

    public func rescheduleQueuedJobs(_ scope: QueuedJobScope, expectedCount: Int, delayMinutes: Int) async throws -> QueuedJobReceipt {
        let delay = min(max(delayMinutes, 0), maxRescheduleDelayMinutes)
        return try apply("reschedule", scope, expectedCount: expectedCount, scheduledAt: Date().addingTimeInterval(Double(delay) * 60))
    }

    // MARK: Costs

    /// The ledger's coverage: swept three hours ago, or, after *Sweep now*, the re-scan that
    /// the ask starts, which the next read finds finished.
    func ledgerCoverage(now: Date) -> CostSnapshot.Coverage {
        if sweepInFlight {
            sweepInFlight = false
            sweptAt = now
        }
        return CostSnapshot.Coverage(status: "complete", complete: true, progressPct: 100, directoriesDone: 212, directoriesTotal: 212,
                                     filesScanned: 18_440, finishedAt: sweptAt, lastRanAt: sweptAt,
                                     coversSince: now.addingTimeInterval(-140 * 86_400), coversUntil: now.addingTimeInterval(-7 * 60))
    }

    public func backfillCosts() async throws -> BackfillRequest {
        sweepInFlight = true
        let now = Date()
        return BackfillRequest(queued: true, runStatus: "running", coverage: CostSnapshot.Coverage(
            status: "running", complete: true, progressPct: 0, directoriesDone: 0, directoriesTotal: 212, filesScanned: 0,
            finishedAt: sweptAt, lastRanAt: now, coversSince: now.addingTimeInterval(-140 * 86_400), coversUntil: now.addingTimeInterval(-7 * 60)))
    }

    // MARK: CLIs

    /// `CliStatusService`'s report, in the server's JSON: two tools ready, one installed but
    /// signed out, one keyed by an environment variable, one not installed.
    static func sampleCliTools() -> [String: Any] {
        [
            "gh": ["name": "GitHub CLI", "installed": true, "authenticated": true, "version": "2.62.0", "details": NSNull(),
                   "install_instructions": "# Pre-installed in Docker image\n# To update: npm install -g gh",
                   "auth_instructions": "gh auth login", "auth_method": "oauth", "env_var_name": NSNull()],
            "claude": ["name": "Claude Code", "installed": true, "authenticated": true, "version": "2.0.14", "details": NSNull(),
                       "install_instructions": "# Pre-installed in Docker image\nnpm install -g @anthropic-ai/claude-code",
                       "auth_instructions": "claude login", "auth_method": "oauth", "env_var_name": NSNull()],
            "codex": ["name": "OpenAI Codex", "installed": true, "authenticated": false, "version": "0.41.0", "details": NSNull(),
                      "install_instructions": "# Pre-installed in Docker image (npm i -g @openai/codex)",
                      "auth_instructions": "# Sign in with your ChatGPT account:\ncodex login\n# Or with an API key:\ncodex login --api-key",
                      "auth_method": "oauth", "env_var_name": NSNull()],
            "pi": ["name": "Pi Coding Agent", "installed": true, "authenticated": true, "version": "0.9.3",
                   "details": "3 extensions loaded: zimmer-tools, zimmer-hooks, zimmer-skills",
                   "install_instructions": "# Pre-installed in Docker image (npm i -g @earendil-works/pi-coding-agent)",
                   "auth_instructions": "export OPENROUTER_API_KEY=...", "auth_method": "env_var", "env_var_name": "OPENROUTER_API_KEY"],
            "fly": ["name": "Fly.io CLI", "installed": false, "authenticated": false, "version": NSNull(), "details": NSNull(),
                    "install_instructions": "# Pre-installed in Docker image\ncurl -L https://fly.io/install.sh | sh",
                    "auth_instructions": NSNull(), "auth_method": "env_var", "env_var_name": "FLY_IO_API_TOKEN"],
        ]
    }

    private func cliReportJSON() -> [String: Any] {
        let tools = cliReport.compactMapValues { $0 as? [String: Any] }
        let unauthenticated = tools.values.filter { ($0["authenticated"] as? Bool) != true }.count
        return [
            "tools": cliReport, "all_authenticated": unauthenticated == 0, "unauthenticated_count": unauthenticated,
            "generated_at": cliCheckedAt.formatted(.iso8601), "loading": false,
        ]
    }

    public func cliStatus() async throws -> CliStatusReport {
        let report = cliReportJSON()
        return try CliStatusReport.parse(JSONSerialization.data(withJSONObject: ["cli_status": report, "unauthenticated_count": report["unauthenticated_count"] ?? 0]))
    }

    /// The refresh job runs at once here: the check is re-stamped, so a status line that
    /// reads "checked just now" after a refresh is reading the fixture's answer.
    public func refreshCliStatus() async throws -> CliStatusReport {
        cliCheckedAt = Date()
        return try CliStatusReport.parse(JSONSerialization.data(withJSONObject: ["queued": true, "message": "CLI status refresh queued", "current_status": cliReportJSON()]))
    }

    public func clearCliCache() async throws -> String {
        "Cache clear queued. Caches will be cleared in the worker container and MCP packages reinstalled."
    }

    /// How many tools the board's CLIs badge counts.
    public var cliIssues: Int {
        cliReport.compactMapValues { $0 as? [String: Any] }.values.filter { ($0["authenticated"] as? Bool) != true }.count
    }
}
