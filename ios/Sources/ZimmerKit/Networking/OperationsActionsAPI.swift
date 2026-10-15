import Foundation

/// The operator actions the web's Health, Costs and CLIs pages offer any signed-in person,
/// on the routes the app's token opens for exactly them: the Health page's buttons
/// (cleanup, retries, trashing, queue recovery mode, the queued-job levers, re-arming the
/// post-deploy tasks), the Costs page's *Sweep now*, and the CLIs page whole.
public protocol OperationsActionsAPI: Sendable {
    /// End the orphaned agent processes the report lists. Cooled down: one every thirty seconds.
    func cleanupProcesses() async throws -> ProcessCleanup
    /// Restart the recent failed sessions, as the web button does (the server picks the ten
    /// most recent of the last day). Cooled down.
    func retryFailedSessions() async throws -> SessionRetry
    /// Trash every session untouched for `days` days (1…365). Cooled down.
    func archiveOldSessions(days: Int) async throws -> SessionArchive
    /// Halt the demand-side queues, or extend the halt: entering while on resets the timer.
    /// `ttlMinutes` is clamped to 5…240 by the server; nil is its default hour.
    func enterQueueRecoveryMode(reason: String?, ttlMinutes: Int?) async throws -> HealthReport.QueueRecovery
    /// Resume normal processing. Idempotent and never refused.
    func exitQueueRecoveryMode() async throws -> HealthReport.QueueRecovery
    /// Re-arm any failed one-time post-deploy task and enqueue a pass.
    func runPostDeployTasks() async throws -> PostDeployRearm
    /// Count what a discard or reschedule of `scope` would touch — the count the write demands.
    func queuedJobs(_ scope: QueuedJobScope) async throws -> QueuedJobPreview
    /// Discard the queued jobs in `scope`. Not recoverable; refused unless `expectedCount`
    /// is what the server counts now.
    func discardQueuedJobs(_ scope: QueuedJobScope, expectedCount: Int, reason: String?) async throws -> QueuedJobReceipt
    /// Move the queued jobs in `scope` to run `delayMinutes` from now (0: as soon as the
    /// queue allows). Same count rule.
    func rescheduleQueuedJobs(_ scope: QueuedJobScope, expectedCount: Int, delayMinutes: Int) async throws -> QueuedJobReceipt
    /// Ask for a sweep of the whole transcript corpus into the ledger; returns the run already
    /// in flight rather than starting a second one.
    func backfillCosts() async throws -> BackfillRequest
    /// The CLI tools' cached status; never blocks on a shell.
    func cliStatus() async throws -> CliStatusReport
    /// Queue a fresh check of every tool; answers with the status as cached now.
    func refreshCliStatus() async throws -> CliStatusReport
    /// Queue clearing the worker's npm and pip caches and reinstalling the MCP packages;
    /// returns the server's own sentence about it.
    func clearCliCache() async throws -> String
}

// `ZimmerHTTPClient: ZimmerAPI`, which refines `OperationsActionsAPI`.
extension ZimmerHTTPClient {
    public func cleanupProcesses() async throws -> ProcessCleanup {
        ProcessCleanup.parse(try await postObject("/api/v1/health/cleanup_processes", json: [:]))
    }

    public func retryFailedSessions() async throws -> SessionRetry {
        // No `session_ids`: the server's default is the web button's set, the recent failures.
        SessionRetry.parse(try await postObject("/api/v1/health/retry_sessions", json: [:]))
    }

    public func archiveOldSessions(days: Int) async throws -> SessionArchive {
        SessionArchive.parse(try await postObject("/api/v1/health/archive_old", json: ["days": days]))
    }

    public func enterQueueRecoveryMode(reason: String?, ttlMinutes: Int?) async throws -> HealthReport.QueueRecovery {
        var body: [String: Any] = [:]
        if let reason, !reason.isEmpty { body["reason"] = reason }
        if let ttlMinutes { body["ttl_minutes"] = ttlMinutes }
        return HealthReport.queueRecovery(try await postObject("/api/v1/health/enter_queue_recovery_mode", json: body))
    }

    public func exitQueueRecoveryMode() async throws -> HealthReport.QueueRecovery {
        HealthReport.queueRecovery(try await postObject("/api/v1/health/exit_queue_recovery_mode", json: [:]))
    }

    public func runPostDeployTasks() async throws -> PostDeployRearm {
        PostDeployRearm.parse(try await postObject("/api/v1/health/run_post_deploy_tasks", json: [:]))
    }

    public func queuedJobs(_ scope: QueuedJobScope) async throws -> QueuedJobPreview {
        let query = scope.json.compactMapValues { $0 as? String }
        let response = try await perform(method: "GET", path: "/api/v1/health/queued_jobs", query: query, body: nil)
        return QueuedJobPreview.parse(try object(response.body, at: "/api/v1/health/queued_jobs"))
    }

    public func discardQueuedJobs(_ scope: QueuedJobScope, expectedCount: Int, reason: String?) async throws -> QueuedJobReceipt {
        var body = scope.json
        body["expected_count"] = expectedCount
        if let reason, !reason.isEmpty { body["reason"] = reason }
        return QueuedJobReceipt.parse(try await postObject("/api/v1/health/discard_queued_jobs", json: body))
    }

    public func rescheduleQueuedJobs(_ scope: QueuedJobScope, expectedCount: Int, delayMinutes: Int) async throws -> QueuedJobReceipt {
        var body = scope.json
        body["expected_count"] = expectedCount
        body["delay_minutes"] = delayMinutes
        return QueuedJobReceipt.parse(try await postObject("/api/v1/health/reschedule_queued_jobs", json: body))
    }

    public func backfillCosts() async throws -> BackfillRequest {
        let response = try await perform(method: "POST", path: "/api/v1/costs/backfill", query: [:], body: Data("{}".utf8))
        return try BackfillRequest.parse(response.body)
    }

    public func cliStatus() async throws -> CliStatusReport {
        let response = try await perform(method: "GET", path: "/api/v1/clis/status", query: [:], body: nil)
        return try CliStatusReport.parse(response.body)
    }

    public func refreshCliStatus() async throws -> CliStatusReport {
        let response = try await perform(method: "POST", path: "/api/v1/clis/refresh", query: [:], body: Data("{}".utf8))
        return try CliStatusReport.parse(response.body)
    }

    public func clearCliCache() async throws -> String {
        let answer = try await postObject("/api/v1/clis/clear_cache", json: [:])
        return answer.string("message") ?? "Cache clear queued."
    }

    /// A POST whose answer is read field by field, as the health report is: these are
    /// hand-built hashes, and one odd value must cost one figure, not the action's receipt.
    private func postObject(_ path: String, json: [String: Any]) async throws -> JSONObject {
        let body = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        let response = try await perform(method: "POST", path: path, query: [:], body: body)
        return try object(response.body, at: path)
    }

    private func object(_ data: Data, at path: String) throws -> JSONObject {
        guard let object = JSONObject(try JSONSerialization.jsonObject(with: data)) else { throw ZimmerError.decoding("\(path): not an object") }
        return object
    }
}
