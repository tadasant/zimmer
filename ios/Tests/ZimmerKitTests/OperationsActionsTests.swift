import XCTest
@testable import ZimmerKit

/// The Health page's operator actions, the Costs page's Sweep now, and the CLIs page.
final class OperationsActionsTests: XCTestCase {
    private func client(_ handlers: [ScriptedTransport.Handler]) -> (ZimmerHTTPClient, ScriptedTransport) {
        let transport = ScriptedTransport(handlers)
        return (ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport), transport)
    }

    private func body(_ request: HTTPRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: request.body ?? Data("{}".utf8)) as? [String: Any])
    }

    private func query(_ request: HTTPRequest) -> [String: String] {
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testEachHealthActionHitsItsRouteWithTheControllersParams() async throws {
        let (api, transport) = client([
            { _ in Fixtures.json(200, ["terminated": [48_112], "failed": [["pid": 9, "reason": "EPERM"]], "already_dead": [7]]) },
            { _ in Fixtures.json(200, ["retried": [1027], "failed": [], "skipped": [["session_id": 1019, "reason": "worktree gone"]]]) },
            { _ in Fixtures.json(200, ["archived": [1001, 1002, 1003], "failed": []]) },
            { _ in Fixtures.json(200, ["active": true, "entered_at": "2026-10-11T01:00:00Z", "expires_at": "2026-10-11T02:30:00Z", "expires_in_seconds": 5400,
                                       "reason": "stampede", "entered_by": "the iOS app (t@example.com)",
                                       "halted_queues": ["pollers"], "paused_queues": ["pollers"], "live_queues": ["agents"]]) },
            { _ in Fixtures.json(200, ["active": false, "entered_at": NSNull(), "expires_at": NSNull(), "halted_queues": ["pollers"], "paused_queues": [], "live_queues": ["agents"]]) },
            { _ in Fixtures.json(200, ["rearmed": 1, "enqueued": true, "status": "warning", "total": 3, "pending": 1, "running": 0, "succeeded": 2, "failed": 0]) },
        ])

        let cleanup = try await api.cleanupProcesses()
        let retry = try await api.retryFailedSessions()
        let archive = try await api.archiveOldSessions(days: 7)
        let entered = try await api.enterQueueRecoveryMode(reason: "stampede", ttlMinutes: 90)
        let exited = try await api.exitQueueRecoveryMode()
        let rearm = try await api.runPostDeployTasks()

        XCTAssertEqual(transport.sent.map { "\($0.method) \($0.url.path)" }, [
            "POST /api/v1/health/cleanup_processes", "POST /api/v1/health/retry_sessions", "POST /api/v1/health/archive_old",
            "POST /api/v1/health/enter_queue_recovery_mode", "POST /api/v1/health/exit_queue_recovery_mode", "POST /api/v1/health/run_post_deploy_tasks",
        ])
        XCTAssertEqual(try body(transport.sent[1]).isEmpty, true, "no session_ids: the server's default is the web button's set")
        XCTAssertEqual(try body(transport.sent[2])["days"] as? Int, 7)
        let enter = try body(transport.sent[3])
        XCTAssertEqual(enter["reason"] as? String, "stampede")
        XCTAssertEqual(enter["ttl_minutes"] as? Int, 90)

        XCTAssertEqual(cleanup.terminated, [48_112])
        XCTAssertEqual(cleanup.failed.first?.reason, "EPERM")
        XCTAssertEqual(cleanup.summary, "Terminated 1 process; 1 already gone; 1 could not be ended.")
        XCTAssertEqual(retry.retried, [1027])
        XCTAssertEqual(retry.skipped.first?.reason, "worktree gone")
        XCTAssertEqual(retry.summary, "Retried 1 session; 1 skipped.")
        XCTAssertEqual(archive.archived.count, 3)
        XCTAssertEqual(archive.summary, "Trashed 3 sessions.")
        XCTAssertTrue(entered.active)
        XCTAssertEqual(entered.enteredBy, "the iOS app (t@example.com)")
        XCTAssertEqual(entered.expiresInSeconds, 5400)
        XCTAssertFalse(exited.active)
        XCTAssertEqual(exited.summary, "Job processing resumed.")
        XCTAssertEqual(rearm.rearmed, 1)
        XCTAssertEqual(rearm.summary, "Re-armed 1 failed task; a pass is queued.")
    }

    func testABlankReasonAndADefaultTTLAreLeftOut() async throws {
        let (api, transport) = client([{ _ in Fixtures.json(200, ["active": true, "halted_queues": [], "paused_queues": [], "live_queues": []]) }])
        _ = try await api.enterQueueRecoveryMode(reason: "", ttlMinutes: nil)
        XCTAssertTrue(try body(transport.sent[0]).isEmpty, "the server's default hour and no reason")
    }

    func testTheCooldownIsAnHTTP429TheScreenShowsInPlace() async throws {
        let (api, _) = client([
            { _ in Fixtures.json(429, ["error": "Rate limited", "message": "Please wait 30 seconds between actions", "retry_after": 30]) },
            { _ in Fixtures.json(503, ["error": "Rate limiting unavailable", "message": "The cache is unavailable, so the 30-second cooldown cannot be enforced."]) },
        ])
        do {
            _ = try await api.cleanupProcesses()
            XCTFail("refused")
        } catch let error as ZimmerError {
            XCTAssertTrue(error.isCooldown)
            XCTAssertEqual(error, .http(status: 429, message: "Please wait 30 seconds between actions"))
        }
        do {
            _ = try await api.archiveOldSessions(days: 7)
            XCTFail("refused")
        } catch let error as ZimmerError {
            XCTAssertFalse(error.isCooldown, "a cache outage is a failure, not a wait")
        }
    }

    func testQueuedJobsArePreviewedThenDiscardedOrRescheduledWithTheCount() async throws {
        let (api, transport) = client([
            { _ in Fixtures.json(200, ["scope": ["job_class": "SlackTriggerPollerJob", "queue_name": NSNull()], "matched": 4,
                                       "by_job_class": ["SlackTriggerPollerJob": 4], "by_queue": ["pollers": 4], "over_cap": false, "max_per_call": 2000]) },
            { _ in Fixtures.json(200, ["action": "discard", "scope": ["job_class": "SlackTriggerPollerJob", "queue_name": "pollers"], "matched": 4, "affected": 4,
                                       "by_job_class": ["SlackTriggerPollerJob": 4], "by_queue": ["pollers": 4], "skipped": [], "skipped_total": 0,
                                       "scheduled_at": NSNull(), "actor": "the iOS app", "performed_at": "2026-10-11T01:00:00Z"]) },
            { _ in Fixtures.json(200, ["action": "reschedule", "scope": ["job_class": "TriggerEvaluationJob", "queue_name": NSNull()], "matched": 2, "affected": 2,
                                       "by_job_class": ["TriggerEvaluationJob": 2], "by_queue": ["triggers": 2], "skipped_total": 1, "scheduled_at": "2026-10-11T01:30:00Z"]) },
            { _ in Fixtures.json(422, ["error": "Refused", "message": "Expected 4 queued jobs in scope, found 3; nothing was changed."]) },
        ])

        let preview = try await api.queuedJobs(QueuedJobScope(jobClass: "SlackTriggerPollerJob"))
        let discarded = try await api.discardQueuedJobs(QueuedJobScope(jobClass: "SlackTriggerPollerJob", queueName: "pollers"), expectedCount: 4,
                                                       reason: "discarded from the Health screen in the iOS app")
        let rescheduled = try await api.rescheduleQueuedJobs(QueuedJobScope(jobClass: "TriggerEvaluationJob"), expectedCount: 2, delayMinutes: 30)

        XCTAssertEqual(transport.sent[0].method, "GET")
        XCTAssertEqual(transport.sent[0].url.path, "/api/v1/health/queued_jobs")
        XCTAssertEqual(query(transport.sent[0]), ["job_class": "SlackTriggerPollerJob"], "only the half of the scope that is set")
        XCTAssertEqual(transport.sent[1].url.path, "/api/v1/health/discard_queued_jobs")
        let discard = try body(transport.sent[1])
        XCTAssertEqual(discard["job_class"] as? String, "SlackTriggerPollerJob")
        XCTAssertEqual(discard["queue_name"] as? String, "pollers")
        XCTAssertEqual(discard["expected_count"] as? Int, 4)
        XCTAssertEqual(discard["reason"] as? String, "discarded from the Health screen in the iOS app")
        let reschedule = try body(transport.sent[2])
        XCTAssertEqual(transport.sent[2].url.path, "/api/v1/health/reschedule_queued_jobs")
        XCTAssertEqual(reschedule["expected_count"] as? Int, 2)
        XCTAssertEqual(reschedule["delay_minutes"] as? Int, 30)
        XCTAssertNil(reschedule["queue_name"])

        XCTAssertEqual(preview.matched, 4)
        XCTAssertEqual(preview.label, "SlackTriggerPollerJob on pollers", "the web row's label, from the queue the preview found")
        XCTAssertEqual(discarded.affected, 4)
        XCTAssertEqual(discarded.summary, "Discarded 4 queued jobs (SlackTriggerPollerJob on pollers).")
        XCTAssertEqual(rescheduled.action, "reschedule")
        XCTAssertNotNil(rescheduled.scheduledAt)
        XCTAssertTrue(rescheduled.summary.hasPrefix("Rescheduled 2 queued jobs (TriggerEvaluationJob) to run at "))
        XCTAssertTrue(rescheduled.summary.hasSuffix("; 1 skipped."))
        await XCTAssertThrowsAsync(try await api.discardQueuedJobs(QueuedJobScope(jobClass: "X"), expectedCount: 4, reason: nil), "a count mismatch is refused")
    }

    func testSweepNowPostsAndReadsTheRunAndTheCoverage() async throws {
        let (api, transport) = client([{ _ in Fixtures.json(200, [
            "queued": true,
            "run": ["id": 9, "status": "queued", "trigger": "manual", "directories_done": 0, "directories_total": 0, "files_scanned": 0, "rows_written": 0,
                    "started_at": NSNull(), "finished_at": NSNull()],
            "ledger_coverage": ["status": "queued", "complete": true, "progress_pct": NSNull(), "covers_since": "2026-05-01T00:00:00Z", "finished_at": "2026-10-10T00:00:00Z"],
        ]) }])

        let request = try await api.backfillCosts()

        XCTAssertEqual(transport.sent.map { "\($0.method) \($0.url.path)" }, ["POST /api/v1/costs/backfill"])
        XCTAssertTrue(request.queued)
        XCTAssertEqual(request.runStatus, "queued")
        XCTAssertEqual(request.coverage?.headline, "History sweep queued")
        XCTAssertNotNil(request.coverage?.coversSince)
    }

    func testTheCLIsPageReadsRefreshesAndClearsTheCache() async throws {
        let (api, transport) = client([
            { _ in Fixtures.json(200, ["cli_status": ["tools": Self.tools(), "all_authenticated": false, "unauthenticated_count": 2, "generated_at": "2026-10-11T01:00:00Z"],
                                       "unauthenticated_count": 2]) },
            { _ in Fixtures.json(200, ["queued": true, "message": "CLI status refresh queued",
                                       "current_status": ["tools": Self.tools(), "all_authenticated": false, "unauthenticated_count": 2, "generated_at": "2026-10-11T01:05:00Z"]]) },
            { _ in Fixtures.json(200, ["queued": true, "message": "Cache clear queued. Caches will be cleared in the worker container and MCP packages reinstalled."]) },
        ])

        let status = try await api.cliStatus()
        let refreshed = try await api.refreshCliStatus()
        let cleared = try await api.clearCliCache()

        XCTAssertEqual(transport.sent.map { "\($0.method) \($0.url.path)" }, [
            "GET /api/v1/clis/status", "POST /api/v1/clis/refresh", "POST /api/v1/clis/clear_cache",
        ])
        XCTAssertEqual(status.tools.map(\.key), ["gh", "codex", "fly", "zz"], "the server's order, then anything unknown by name")
        XCTAssertEqual(status.headline, "2 CLI tools need attention")
        XCTAssertEqual(status.unauthenticatedCount, 2)
        XCTAssertEqual(status.tools[2].installedLabel, "Not Installed")
        XCTAssertEqual(status.tools[2].installInstructions, "curl fly", "trimmed, as the page prints it")
        XCTAssertEqual(status.tools[2].envVarHint, "FLY_IO_API_TOKEN=your_token_here")
        XCTAssertEqual(status.tools[1].authenticatedLabel, "Not Authenticated")
        XCTAssertEqual(status.tools[1].authInstructions, "codex login")
        XCTAssertTrue(status.tools[0].isReady)
        XCTAssertNotNil(status.generatedAt)
        XCTAssertEqual(refreshed.generatedAt?.timeIntervalSince(try XCTUnwrap(status.generatedAt)), 300, "the refresh answers with the status as cached now")
        XCTAssertTrue(cleared.hasPrefix("Cache clear queued."))
    }

    /// Four tools in no particular order: the parser puts the server's known ones first.
    private static func tools() -> [String: Any] {
        [
            "fly": ["name": "Fly.io CLI", "installed": false, "authenticated": false, "version": NSNull(), "install_instructions": "curl fly\n",
                    "auth_instructions": NSNull(), "auth_method": "env_var", "env_var_name": "FLY_IO_API_TOKEN"],
            "gh": ["name": "GitHub CLI", "installed": true, "authenticated": true, "version": "2.62.0", "auth_method": "oauth"],
            "codex": ["name": "OpenAI Codex", "installed": true, "authenticated": false, "version": "0.41.0", "auth_instructions": "codex login\n", "auth_method": "oauth"],
            "zz": ["name": "Something newer", "installed": true, "authenticated": true],
        ]
    }

    func testTheCLIsPlaceholderBeforeTheFirstCheckReadsAsChecking() throws {
        let report = try CliStatusReport.parse(Data(#"""
        {"cli_status": {"tools": {"gh": {"name": "GitHub CLI", "installed": null, "authenticated": null, "loading": true}},
         "all_authenticated": null, "unauthenticated_count": 0, "generated_at": null, "loading": true}, "unauthenticated_count": 0}
        """#.utf8))
        XCTAssertTrue(report.loading)
        XCTAssertEqual(report.headline, "Checking CLI tools…")
        XCTAssertEqual(report.tools.first?.installedLabel, "Checking…")
        XCTAssertNil(report.tools.first?.installed)
        XCTAssertEqual(CliStatusReport(tools: [], allAuthenticated: true, unauthenticatedCount: 0).headline, "All CLI tools are installed and authenticated")
        XCTAssertEqual(CliStatusReport(tools: [], allAuthenticated: false, unauthenticatedCount: 1).headline, "1 CLI tool needs attention")
    }

    func testTheFixtureAnswersEachActionAndRefusesAsTheServerDoes() async throws {
        let fake = FakeZimmerAPI()

        let before = try await fake.health()
        XCTAssertEqual(before.process?.orphaned, 1)
        let cleanup = try await fake.cleanupProcesses()
        XCTAssertEqual(cleanup.terminated, [48_112])
        let after = try await fake.health()
        XCTAssertEqual(after.process?.orphaned, 0, "the report reads back what the action did")
        XCTAssertTrue(after.process?.orphans.isEmpty ?? false)
        do {
            _ = try await fake.cleanupProcesses()
            XCTFail("the second within thirty seconds is refused")
        } catch let error as ZimmerError {
            XCTAssertTrue(error.isCooldown)
        }

        let retry = try await fake.retryFailedSessions()
        XCTAssertEqual(retry.retried, [1027, 1019])
        let afterRetry = try await fake.health()
        XCTAssertEqual(afterRetry.session?.recentFailures.count, 0)
        let retried = try await fake.session(1027)
        XCTAssertEqual(retried.session.status, .waiting, "a retried session is waiting to run again")

        let archive = try await fake.archiveOldSessions(days: 7)
        XCTAssertTrue(archive.archived.isEmpty, "nothing in the fixture is untouched for a week, so the sweep finds nothing, as the server's would")
        XCTAssertEqual(archive.summary, "Trashed 0 sessions.")

        let entered = try await fake.enterQueueRecoveryMode(reason: "stampede", ttlMinutes: 1)
        XCTAssertTrue(entered.active)
        XCTAssertEqual(entered.reason, "stampede")
        XCTAssertEqual(try XCTUnwrap(entered.expiresAt).timeIntervalSinceNow, 5 * 60, accuracy: 5, "the TTL is clamped to the server's floor")
        let halted = try await fake.health()
        XCTAssertTrue(halted.queueRecovery?.active ?? false)
        XCTAssertFalse(halted.banners.isEmpty, "the board's banner follows")
        let extended = try await fake.enterQueueRecoveryMode(reason: nil, ttlMinutes: 120)
        XCTAssertEqual(extended.reason, "stampede", "an extension keeps the entry's reason")
        XCTAssertEqual(try XCTUnwrap(extended.expiresAt).timeIntervalSinceNow, 120 * 60, accuracy: 5)
        let exited = try await fake.exitQueueRecoveryMode()
        XCTAssertFalse(exited.active)
        let resumed = try await fake.health()
        XCTAssertTrue(resumed.banners.isEmpty)

        XCTAssertEqual(resumed.postDeployTasks?.failed, 1)
        let rearm = try await fake.runPostDeployTasks()
        XCTAssertEqual(rearm.rearmed, 1)
        let rearmed = try await fake.health()
        XCTAssertEqual(rearmed.postDeployTasks?.failed, 0)
        let again = try await fake.runPostDeployTasks()
        XCTAssertEqual(again.rearmed, 0, "idempotent")

        let preview = try await fake.queuedJobs(QueuedJobScope(jobClass: "SlackTriggerPollerJob"))
        XCTAssertEqual(preview.matched, 4)
        XCTAssertEqual(preview.label, "SlackTriggerPollerJob on pollers")
        await XCTAssertThrowsAsync(try await fake.discardQueuedJobs(QueuedJobScope(jobClass: "SlackTriggerPollerJob"), expectedCount: 3, reason: nil),
                                   "a count the queue has moved past is refused")
        await XCTAssertThrowsAsync(try await fake.queuedJobs(QueuedJobScope()), "an unscoped call is refused")
        await XCTAssertThrowsAsync(try await fake.discardQueuedJobs(QueuedJobScope(queueName: "agents"), expectedCount: 0, reason: nil), "the live queue is protected")
        let discarded = try await fake.discardQueuedJobs(QueuedJobScope(jobClass: "SlackTriggerPollerJob"), expectedCount: 4, reason: "test")
        XCTAssertEqual(discarded.affected, 4)
        let afterDiscard = try await fake.health()
        XCTAssertEqual(afterDiscard.system?.readyByJobClass.map(\.name), ["TriggerEvaluationJob"], "the discarded class is gone from the backlog")
        let rescheduled = try await fake.rescheduleQueuedJobs(QueuedJobScope(jobClass: "TriggerEvaluationJob"), expectedCount: 2, delayMinutes: 10)
        XCTAssertEqual(rescheduled.affected, 2)
        let afterReschedule = try await fake.health()
        XCTAssertEqual(afterReschedule.system?.readyByJobClass.count, 1, "rescheduled jobs are still queued")
    }

    func testTheFixturesSweepIsInFlightThenDoneOnTheNextRead() async throws {
        let fake = FakeZimmerAPI()
        let before = try await fake.costs(.days(7), scope: .fleet)
        XCTAssertEqual(before.coverage?.headline, "History backfilled")
        let request = try await fake.backfillCosts()
        XCTAssertEqual(request.coverage?.headline, "Re-scanning history — 0%", "a sweep after a finished one is a re-scan")
        let after = try await fake.costs(.days(7), scope: .fleet)
        XCTAssertEqual(after.coverage?.headline, "History backfilled")
        XCTAssertEqual(try XCTUnwrap(after.coverage?.finishedAt).timeIntervalSinceNow, 0, accuracy: 5, "swept just now")
    }

    func testTheFixturesCLIsReadAndAreReStampedByARefresh() async throws {
        let fake = FakeZimmerAPI()
        let status = try await fake.cliStatus()
        XCTAssertEqual(status.tools.map(\.key), ["gh", "claude", "codex", "pi", "fly"])
        XCTAssertEqual(status.unauthenticatedCount, 2)
        let issues = await fake.cliIssues
        XCTAssertEqual(issues, 2, "the badge the board shows")
        XCTAssertEqual(status.headline, "2 CLI tools need attention")
        XCTAssertEqual(try XCTUnwrap(status.generatedAt).timeIntervalSinceNow, -120, accuracy: 5)
        let refreshed = try await fake.refreshCliStatus()
        XCTAssertEqual(try XCTUnwrap(refreshed.generatedAt).timeIntervalSinceNow, 0, accuracy: 5)
        let cleared = try await fake.clearCliCache()
        XCTAssertTrue(cleared.hasPrefix("Cache clear queued."))
    }
}
