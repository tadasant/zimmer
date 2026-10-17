import XCTest
@testable import ZimmerKit

/// Slice 5: the inbox, triggers, costs and health.
final class OperationsTests: XCTestCase {
    private func client(_ handlers: [ScriptedTransport.Handler]) -> (ZimmerHTTPClient, ScriptedTransport) {
        let transport = ScriptedTransport(handlers)
        return (ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport), transport)
    }

    private let noContent: ScriptedTransport.Handler = { _ in HTTPResponse(statusCode: 204, headers: ["x-request-id": "r"], body: Data()) }

    func testTheInboxReadsAndEachActionHitsItsRoute() async throws {
        let (api, transport) = client([
            { _ in Fixtures.json(200, ["notifications": [[
                "id": 9, "notification_type": "needs_input", "read": false, "stale": false, "created_at": "2026-10-11T01:00:00Z",
                "session": ["id": 1038, "title": "Merge?", "status": "needs_input"],
            ]]]) },
            { _ in Fixtures.json(200, ["pending_count": 3]) },
            { _ in Fixtures.json(200, ["notification": ["id": 9, "read": true]]) },
            { _ in Fixtures.json(200, ["marked_count": 2, "pending_count": 0]) },
            noContent,
            { _ in Fixtures.json(200, ["dismissed_count": 1, "pending_count": 0]) },
        ])

        let inbox = try await api.notifications()
        let unread = try await api.unreadNotificationCount()
        let read = try await api.markNotificationRead(9)
        try await api.markAllNotificationsRead()
        try await api.dismissNotification(9)
        try await api.dismissAllReadNotifications()

        XCTAssertEqual(inbox.first?.headline, "Needs your input")
        XCTAssertEqual(inbox.first?.session?.id, 1038)
        XCTAssertEqual(unread, 3)
        XCTAssertTrue(read.read)
        XCTAssertEqual(transport.sent.map { "\($0.method) \($0.url.path)" }, [
            "GET /api/v1/notifications", "GET /api/v1/notifications/badge", "PATCH /api/v1/notifications/9/mark_read",
            "PATCH /api/v1/notifications/mark_all_read", "DELETE /api/v1/notifications/9/dismiss",
            "DELETE /api/v1/notifications/dismiss_all_read",
        ])
    }

    func testTriggersListToggleAndInvoke() async throws {
        let (api, transport) = client([
            { _ in Fixtures.json(200, ["triggers": [[
                "id": 5, "name": "Nightly", "status": "enabled", "agent_root_name": "zimmer", "last_triggered_at": "2026-10-11T00:00:00Z",
                "conditions": [["condition_type": "schedule", "description": "Daily 02:00", "configuration": ["time": "02:00"]]],
            ]]]) },
            { _ in Fixtures.json(200, ["trigger": ["id": 5, "name": "Nightly", "status": "disabled", "conditions": []]]) },
            { _ in Fixtures.json(201, ["trigger": ["id": 5], "session": ["id": 2001, "title": "x", "status": "waiting"], "message": "Fired"]) },
        ])

        let list = try await api.triggers()
        let toggled = try await api.toggleTrigger(5)
        let invoked = try await api.invokeTrigger(5)

        XCTAssertEqual(list.first?.conditions.first?.description, "Daily 02:00")
        XCTAssertTrue(list.first?.isEnabled ?? false)
        XCTAssertFalse(toggled.isEnabled)
        XCTAssertEqual(invoked.sessionID, 2001)
        XCTAssertEqual(transport.sent.map { "\($0.method) \($0.url.path)" }, [
            "GET /api/v1/triggers", "POST /api/v1/triggers/5/toggle", "POST /api/v1/triggers/5/invoke",
        ])
    }

    func testEachInvokeOutcomeIsToldApart() async throws {
        let (api, _) = client([
            { _ in Fixtures.json(201, ["trigger": ["id": 5], "session": ["id": 1], "burst_notice": true, "message": "Burst"]) },
            { _ in Fixtures.json(409, ["error": "No session created", "message": "A session is still pending", "session": ["id": 2]]) },
            { _ in Fixtures.json(422, ["error": "No session created", "message": "Not reusable", "session": ["id": 3]]) },
            { _ in Fixtures.json(422, ["error": "Invalid agent_root", "message": "Agent root 'x' not found"]) },
            { _ in Fixtures.json(429, ["error": "Burst suppressed", "message": "Too many fires"]) },
        ])

        let burst = try await api.invokeTrigger(5)
        let pending = try await api.invokeTrigger(5)
        let notReusable = try await api.invokeTrigger(5)

        XCTAssertEqual(burst.outcome, .burstNotice)
        XCTAssertFalse(burst.started, "the session asked for was not made")
        XCTAssertEqual(pending.outcome, .pendingSession)
        XCTAssertEqual(pending.sessionID, 2, "the pending session can be opened")
        XCTAssertEqual(notReusable.sessionID, 3)
        await XCTAssertThrowsAsync(try await api.invokeTrigger(5), "a 422 with no session is a refusal")
        await XCTAssertThrowsAsync(try await api.invokeTrigger(5), "a suppressed burst is an error")
    }

    func testCostsReadTheTotalsTheDaysAndTheTopRows() async throws {
        let (api, transport) = client([{ _ in Fixtures.json(200, [
            "window": ["from": "2026-10-04T00:00:00Z", "to": "2026-10-11T00:00:00Z"],
            "totals": ["cost_usd": 369.6, "tokens": 1000],
            "by_day": [["day": "2026-10-10", "cost_usd": 53.4, "session_cost_usd": 50.0]],
            "by_agent_root": [["agent_root": "zimmer", "cost_usd": 201.4, "tokens": 9], ["agent_root": "other (3)", "cost_usd": 10.0]],
            "by_model": [["model": "opus", "cost_usd": 330.1]],
            "top_sessions": [["session_id": 1042, "cost_usd": 23.81, "tokens": 1204331, "api_calls": 90]],
            "pricing": ["x": 1],
        ]) }])

        let costs = try await api.costs(.days(7), scope: .fleet)

        XCTAssertEqual(URLComponents(url: transport.sent[0].url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "7")
        XCTAssertEqual(costs.totalUSD, 369.6, accuracy: 0.001)
        XCTAssertEqual(costs.days.first?.costUSD ?? 0, 53.4, accuracy: 0.001)
        XCTAssertEqual(costs.agentRoots.map(\.label), ["zimmer", "other (3)"])
        XCTAssertEqual(costs.models.first?.label, "opus")
        XCTAssertEqual(costs.topSessions.first?.sessionID, 1042)
        XCTAssertEqual(costs.topSessions.first?.apiCalls, 90)
        XCTAssertEqual(costs.scope, .fleet, "no scope in the response is the fleet")
        XCTAssertNotNil(costs.from)
    }

    func testTheTriggerPageReadsTheTriggerAndTheSessionsItMade() async throws {
        let (api, transport) = client([{ _ in Fixtures.json(200, [
            "trigger": [
                "id": 5, "name": "Nightly", "status": "failed", "failed_at": "2026-10-11T02:00:00Z", "last_error": "boom",
                "agent_root_name": "zimmer", "agent_root_missing_from_catalog": true,
                "reuse_session": true, "enqueue_messages": true, "resuscitate_archived": false, "skip_if_pending_session": true,
                "missed_fire_count": 2, "bursting": false, "max_sessions_per_minute": NSNull(),
                "prompt_template": "Sweep {{date}}", "goal": "Green PRs", "last_session_id": 1031,
                "conditions": [["condition_type": "schedule", "description": "Daily 02:00", "last_triggered_at": "2026-10-11T02:00:00Z"]],
            ],
            "recent_sessions": [
                ["id": 1031, "slug": "s", "title": "Sweep", "status": "waiting", "created_at": "2026-10-11T02:00:00Z"],
                ["id": 1020, "title": NSNull(), "status": "some_new_state", "created_at": "2026-10-10T02:00:00Z"],
            ],
        ]) }])

        let detail = try await api.trigger(5)

        XCTAssertEqual(transport.sent.map { "\($0.method) \($0.url.path)" }, ["GET /api/v1/triggers/5"])
        let trigger = detail.trigger
        XCTAssertTrue(trigger.isFailed)
        XCTAssertEqual(trigger.toggleLabel, "Re-arm", "a failed trigger is re-armed, as the web UI's button says")
        XCTAssertNotNil(trigger.failedAt)
        XCTAssertTrue(trigger.agentRootMissing)
        XCTAssertTrue(trigger.reuseSession)
        XCTAssertTrue(trigger.enqueueMessages)
        XCTAssertFalse(trigger.resuscitateArchived)
        XCTAssertNil(trigger.maxSessionsPerMinute)
        XCTAssertEqual(trigger.promptTemplate, "Sweep {{date}}")
        XCTAssertEqual(trigger.badges, ["Re-uses session", "Enqueues messages", "Skips while pending", "2 missed fires"])
        XCTAssertNotNil(trigger.conditions.first?.lastTriggeredAt)
        XCTAssertEqual(trigger.conditions.first?.label, "Schedule")
        XCTAssertEqual(TriggerSummary.Condition(type: "slack", description: "Slack: @zimmer in #zimmer").detail, "@zimmer in #zimmer",
                       "the badge's words are not printed twice")
        XCTAssertEqual(TriggerSummary.Condition(type: "github_issue", description: "Opened in tadasant/zimmer").label, "GitHub")
        XCTAssertEqual(TriggerSummary.Condition(type: "new_kind", description: nil).label, "New Kind")
        XCTAssertEqual(detail.recentSessions.map(\.id), [1031, 1020])
        XCTAssertEqual(detail.recentSessions.first?.status, .waiting)
        XCTAssertNil(detail.recentSessions.last?.title)
    }

    func testAListTriggerWithoutThePagesFieldsReadsAsOff() throws {
        let trigger = try ZimmerJSON.decoder.decode(TriggerSummary.self, from: Data(#"{"id": 6, "status": "disabled"}"#.utf8))
        XCTAssertFalse(trigger.reuseSession)
        XCTAssertFalse(trigger.enqueueMessages)
        XCTAssertEqual(trigger.missedFireCount, 0)
        XCTAssertEqual(trigger.badges, [])
        XCTAssertEqual(trigger.toggleLabel, "Turn On")
        XCTAssertEqual(TriggerSummary(id: 7, name: "x", status: "enabled", coalesceWindowSeconds: 0).badges, ["No coalescing"],
                       "a window of 0 is the web page's No coalescing")
        XCTAssertEqual(TriggerSummary(id: 7, name: "x", status: "enabled", coalesceWindowSeconds: 60).badges, [])
    }

    func testEachInvokeOutcomeHasItsOwnNotice() {
        XCTAssertEqual(TriggerInvocation(outcome: .started, sessionID: 1, message: "Fired").notice, "Fired")
        XCTAssertEqual(TriggerInvocation(outcome: .burstNotice, sessionID: 1, message: "x").notice, "Burst: no new session. x")
        XCTAssertEqual(TriggerInvocation(outcome: .pendingSession, sessionID: 1, message: "x").notice, "A session is still pending. x")
        XCTAssertEqual(TriggerInvocation(outcome: .notReusable, sessionID: 1, message: "x").notice, "Its session cannot take another turn. x")
    }

    private var pacific: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private func day(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = pacific.timeZone
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: text)!
    }

    func testCostsSendTheWindowAndTheScopeTheWayTheWebPageDoes() async throws {
        let ok: ScriptedTransport.Handler = { _ in Fixtures.json(200, ["totals": ["cost_usd": 1.0], "scope": ["agent_root": "zimmer", "session_id": NSNull()]]) }
        let (api, transport) = client([ok, ok, ok])

        let scoped = try await api.costs(.days(1), scope: .agentRoot("zimmer"))
        _ = try await api.costs(.days(30), scope: .session(1042))
        _ = try await api.costs(.custom(from: day("2026-08-01"), to: day("2026-08-03"), calendar: pacific), scope: .fleet)

        func query(_ index: Int) -> [String: String] {
            let items = URLComponents(url: transport.sent[index].url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        }
        XCTAssertEqual(query(0), ["days": "1", "agent_root": "zimmer"])
        XCTAssertEqual(query(1), ["days": "30", "session_id": "1042"])
        XCTAssertEqual(scoped.scope, .agentRoot("zimmer"), "the response says what it was narrowed to")
        // The device's zone, not the server's; the first day's start to the last day's last moment.
        let range = query(2)
        XCTAssertNil(range["days"])
        XCTAssertNotNil(range["from"])
        XCTAssertNotNil(range["to"])
        let window = CostWindow.custom(from: day("2026-08-01"), to: day("2026-08-03"), calendar: pacific).query(calendar: pacific)
        XCTAssertEqual(window["from"], "2026-08-01T07:00:00.000Z", "the day's start in the phone's zone, written in UTC")
        XCTAssertEqual(window["to"], "2026-08-04T06:59:59.999Z")
    }

    func testARangeEastOfUTCReachesTheServerAsTheSameInstants() throws {
        var kolkata = Calendar(identifier: .gregorian)
        kolkata.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = kolkata.timeZone
        formatter.formatOptions = [.withFullDate]
        let first = formatter.date(from: "2026-08-01")!

        let query = CostWindow.custom(from: first, to: first, calendar: kolkata).query(calendar: kolkata)
        let url = try XCTUnwrap(HTTPEndpoint(method: "GET", path: "/api/v1/costs", query: query).url(relativeTo: Fixtures.base))

        // Midnight in Kolkata is 18:30 the evening before in UTC; no `+` is left for Rack to
        // read as a space.
        XCTAssertEqual(url.query, "from=2026-07-31T18:30:00.000Z&to=2026-08-01T18:29:59.999Z")
    }

    func testAPlusInAQueryValueIsSentEscaped() throws {
        let url = try XCTUnwrap(HTTPEndpoint(method: "GET", path: "/api/v1/costs", query: ["to": "2026-08-01T00:00:00+05:30", "q": "a b"])
            .url(relativeTo: Fixtures.base))
        XCTAssertEqual(url.query, "q=a%20b&to=2026-08-01T00:00:00%2B05:30", "a bare + would reach Rails as a space")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.first(where: { $0.name == "to" })?.value, "2026-08-01T00:00:00+05:30", "and still decodes to itself")
    }

    func testACustomRangeIsResolvedAsTheWebFormResolvesIt() {
        let calendar = pacific
        guard case let .range(from, to) = CostWindow.custom(from: day("2026-08-03"), to: day("2026-08-01"), calendar: calendar) else {
            return XCTFail("a range")
        }
        XCTAssertEqual(from, day("2026-08-01"), "the ends are swapped")
        XCTAssertEqual(to, day("2026-08-03"))

        guard case let .range(clampedFrom, _) = CostWindow.custom(from: day("2019-01-01"), to: day("2026-08-03"), calendar: calendar) else {
            return XCTFail("a range")
        }
        XCTAssertEqual(calendar.dateComponents([.day], from: clampedFrom, to: day("2026-08-03")).day, 364, "a year, ending on the last day")

        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(CostWindow.days(1).label(), "24 hours")
        XCTAssertEqual(CostWindow.days(7).label(), "7 days")
        XCTAssertEqual(CostWindow.days(365).label(), "1 year")
        XCTAssertEqual(CostWindow.custom(from: day("2026-08-01"), to: day("2026-08-03"), calendar: calendar).label(calendar: calendar, locale: locale),
                       "Aug 1 – Aug 3, 2026")
        XCTAssertEqual(CostWindow.custom(from: day("2026-08-01"), to: day("2026-08-01"), calendar: calendar).label(calendar: calendar, locale: locale),
                       "Aug 1, 2026")
        XCTAssertEqual(CostWindow.days(5000).query(), ["days": "365"], "the server's own cap")
        XCTAssertFalse(CostScope.narrowable(agentRoot: "other (3)"), "the folded bucket is several roots")
        XCTAssertTrue(CostScope.narrowable(agentRoot: "zimmer"))
    }

    func testTheFixtureNarrowsCostsAndRecordsWhatATriggerMade() async throws {
        let fake = FakeZimmerAPI()
        let fleet = try await fake.costs(.days(7), scope: .fleet)
        let root = try await fake.costs(.days(7), scope: .agentRoot("motet"))
        let session = try await fake.costs(.days(7), scope: .session(1042))
        XCTAssertEqual(root.agentRoots.map(\.label), ["motet"])
        XCTAssertLessThan(root.totalUSD, fleet.totalUSD)
        XCTAssertEqual(session.topSessions.map(\.sessionID), [1042])
        XCTAssertEqual(session.scope, .session(1042))

        let before = try await fake.trigger(5)
        XCTAssertEqual(before.recentSessions.map(\.id), [1031])
        let invoked = try await fake.invokeTrigger(5)
        let after = try await fake.trigger(5)
        XCTAssertEqual(after.recentSessions.first?.id, invoked.sessionID, "newest first")
        XCTAssertEqual(after.trigger.lastSessionID, invoked.sessionID)
    }

    func testHealthReadsEachSectionsStatusWhicheverShapeItHas() async throws {
        let (api, _) = client([{ _ in Fixtures.json(200, [
            "health_report": [
                "overall_status": ["status": "warning", "message": "One or more warnings detected"],
                "process_health": ["status": "healthy", "orphans": 0],
                "session_health": ["status": ["status": "warning", "message": "Failure rate 12%"], "failure_rate": 0.12],
                "log_retention_health": ["backlog": 3],
                "generated_at": "2026-10-11T01:00:00Z",
            ],
            "rails_env": "production",
        ]) }])

        let health = try await api.health()

        XCTAssertEqual(health.overall.status, "warning")
        XCTAssertEqual(health.sections.map(\.key), ["process_health", "session_health"], "a section with no status is left out")
        XCTAssertEqual(health.sections.last?.message, "Failure rate 12%")
        XCTAssertEqual(health.sections.first?.title, "Process")
        XCTAssertNotNil(health.generatedAt)
    }

    func testHealthReadsEverySectionOfTheWebPage() async throws {
        // The fixture's report is in the server's shape; the parser reads it as it reads the server's.
        let body = try JSONSerialization.data(withJSONObject: FakeZimmerAPI.sampleHealthJSON(now: Date(), degraded: true))
        let (api, _) = client([{ _ in HTTPResponse(statusCode: 200, headers: ["content-type": "application/json"], body: body) }])

        let health = try await api.health()

        XCTAssertEqual(health.overall.status, "warning")
        XCTAssertEqual(health.process?.orphaned, 1)
        XCTAssertEqual(health.process?.orphans.first?.pid, 48_112)
        XCTAssertEqual(health.session?.total, 16)
        XCTAssertEqual(health.session?.byStatus.first, HealthReport.Count("waiting", 5), "largest first")
        XCTAssertEqual(health.session?.recentFailures.map(\.id), [1027, 1019])
        XCTAssertEqual(health.session?.recentFailures.first?.failureReason, "api_error_retries_exhausted")
        XCTAssertEqual(health.system?.queueDepth, 6)
        XCTAssertEqual(health.system?.jobsPerHour, 412)
        XCTAssertEqual(health.system?.headOfLine?.jobClass, "SlackTriggerPollerJob")
        XCTAssertEqual(health.system?.readyByQueue.map(\.name), ["pollers", "triggers"])
        XCTAssertEqual(health.system?.oldestExecutionByQueue.first?.name, "agents", "oldest first")
        XCTAssertEqual(health.system?.database?.poolSize, 10)
        XCTAssertEqual(health.system?.recentErrors.map(\.source), ["session_log", "job"])
        XCTAssertNil(health.system?.recentErrors.last?.sessionID, "a job error has no session")
        XCTAssertTrue(health.egress?.degraded ?? false)
        XCTAssertNotNil(health.egress?.degradedSince)
        XCTAssertEqual(health.auth?.currentAccount, "tadas@example.com")
        XCTAssertEqual(health.auth?.serviceableAccounts, 3)
        XCTAssertEqual(health.sigtermRetry?.recovered, 7)
        XCTAssertEqual(health.sigtermRetry?.recentSessions.first?.retryCount, 1)
        XCTAssertNotNil(health.sigtermRetry?.recentSessions.first?.at, "the SIGTERM table's own timestamp key")
        XCTAssertEqual(health.apiErrorRetry?.delayMode, "escalated")
        XCTAssertEqual(health.apiErrorRetry?.recentQuotaLimits, 1)
        XCTAssertEqual(health.retryBudgets.map(\.label), ["SIGTERM", "API error", "Stall nudge"])
        XCTAssertEqual(health.postDeployTasks?.failed, 1)
        XCTAssertEqual(health.postDeployTasks?.awaitingFirstTick, 1)
        XCTAssertEqual(health.postDeployTasks?.tasks.last?.stats, [HealthReport.Count("triggers", 14)])
        XCTAssertFalse(health.postDeployTasks?.tasks.last?.registered ?? true, "the task file was removed")
        XCTAssertEqual(health.cron?.overdue, 1)
        XCTAssertEqual(health.cron?.behind.map(\.key), ["session_health_monitor", "warm_clone_refill", "burn_rate_recompute"])
        XCTAssertEqual(health.cron?.recovered.map(\.key), ["slack_poll"])
        XCTAssertEqual(health.logRetention?.retentionDays, 14)
        XCTAssertEqual(health.rootData?.nearCap.first?.id, "zimmer-orchestrator/decisions")
        XCTAssertEqual(health.warmClonePool?.targets.map(\.repo), ["zimmer", "motet"], "repo names, without .git")
        XCTAssertEqual(health.warmClonePool?.targets.first?.roots, ["zimmer", "zimmer-orchestrator"])
        XCTAssertEqual(health.warmClonePool?.routerClaimed, 38)
        XCTAssertEqual(health.warmProcessPool?.coldStarts, [HealthReport.Count("model_mismatch", 3), HealthReport.Count("pool_empty", 1)])
        XCTAssertEqual(health.inboundEvents?.sources.map(\.label), ["GitHub", "Slack"])
        XCTAssertEqual(health.inboundEvents?.sources.last?.pollClaims, 88)
        XCTAssertEqual(health.queueRecovery?.haltedQueues.count, 5)
        XCTAssertEqual(health.queueRecovery?.strayPausedQueues, ["exports"], "paused outside the control")
        XCTAssertFalse(health.banners.isEmpty)
        XCTAssertEqual(health.banners.queueRecovery?.reason, "trigger stampede, 900 jobs/hour")

        let quiet = try HealthReport.parse(JSONSerialization.data(withJSONObject: FakeZimmerAPI.sampleHealthJSON(now: Date(), degraded: false)))
        XCTAssertTrue(quiet.banners.isEmpty, "no banner while the mode is off and egress resolves")
        XCTAssertFalse(quiet.queueRecovery?.active ?? true)
    }

    func testAHealthReportMissingSectionsStillReads() throws {
        let health = try HealthReport.parse(Data(#"{"health_report": {"overall_status": "healthy", "system_health": {"status": "healthy", "queue_stats": {"ready_count": "3"}}}}"#.utf8))
        XCTAssertEqual(health.system?.queueDepth, 3, "a number sent as a string still counts")
        XCTAssertNil(health.process)
        XCTAssertNil(health.queueRecovery)
        XCTAssertTrue(health.banners.isEmpty)
        XCTAssertEqual(Format.duration(36_420), "10h 7m")
        XCTAssertEqual(Format.duration(45), "45s")
        XCTAssertEqual(Format.duration(3 * 86_400 + 4 * 3600), "3d 4h")
        XCTAssertEqual(Format.bytes(2_740_000_000), "2.6 GB")
        XCTAssertEqual(Format.compact(1_240_000), "1.2M")
        XCTAssertEqual(Format.compact(880_120), "880K")
    }

    func testCostsReadTheWholePayload() async throws {
        let (api, _) = client([{ _ in Fixtures.json(200, [
            "window": ["from": "2026-10-04T00:00:00Z", "to": "2026-10-11T00:00:00Z"],
            "scope": ["agent_root": NSNull(), "session_id": NSNull()],
            "ledger_coverage": ["status": "running", "complete": true, "progress_pct": 62, "directories_done": 131, "directories_total": 212,
                                "files_scanned": 9000, "rows_written": 100, "trigger": "manual", "started_at": "2026-10-11T00:00:00Z",
                                "finished_at": "2026-10-09T00:00:00Z", "last_ran_at": "2026-10-11T00:00:00Z", "last_error": NSNull(),
                                "covers_since": "2026-05-01T00:00:00Z", "covers_until": "2026-10-10T23:50:00Z"],
            "totals": ["cost_usd": 369.6, "session_cost_usd": 355.3, "adhoc_cost_usd": 14.3, "total_tokens": 16_000_000, "api_calls": 2_195,
                       "input_tokens": 1, "output_tokens": 2],
            "cost_breakdown": [["component": "cache read", "cost_usd": 170.0, "share": 0.46], ["component": "output", "cost_usd": 70.2, "share": 0.19]],
            "by_day": [["day": "2026-10-10", "cost_usd": 53.4, "session_cost_usd": 50.0, "adhoc_cost_usd": 3.4, "tokens": 2_300_000, "api_calls": 310,
                        "roots": [["name": "zimmer", "cost_usd": 30.0, "tokens": 1, "api_calls": 2]], "models": [["name": "claude-opus-4-5", "cost_usd": 50.0, "tokens": 1, "api_calls": 2]]]],
            "by_agent_root": [["agent_root": "zimmer", "cost_usd": 201.4, "tokens": 9_412_000, "api_calls": 1204,
                               "features": [["feature": "skills", "cost_usd": 61.2, "tokens": 2_900_000, "api_calls": 0]]],
                              ["agent_root": "other (3)", "cost_usd": 10.0, "tokens": 5, "api_calls": 1, "features": []]],
            "by_model": [["model": "claude-opus-4-5", "cost_usd": 330.1, "tokens": 1, "api_calls": 1610]],
            "by_thread_kind": [["kind": "main", "cost_usd": 301.2, "tokens": 1, "api_calls": 1702], ["kind": "subagent", "cost_usd": 68.4, "tokens": 1, "api_calls": 455]],
            "by_runtime": [["runtime": "claude_code", "cost_usd": 355.3, "tokens": 1, "api_calls": 2011], ["runtime": "codex", "cost_usd": 0, "tokens": 402_000, "api_calls": 38]],
            "by_adhoc_source": [["source": "session_title", "cost_usd": 9.1, "tokens": 1, "api_calls": 412]],
            "by_feature": ["rows": [["feature": "skills", "cost_usd": 61.2, "tokens": 2_900_000, "api_calls": 0]], "attributed_cost_usd": 61.2,
                           "attributed_tokens": 2_900_000, "total_cost_usd": 355.3, "total_tokens": 15_100_000, "residual_cost_usd": 294.1,
                           "residual_tokens": 12_200_000, "coverage": 0.192],
            "by_experiment": [["key": "compact_tool_results", "title": "Compact tool results", "description": "d", "current_value": true,
                               "landed_at": "2026-10-02T10:00:00Z", "backfilled": true, "tagged_sessions": 83, "tagged_by_source": ["backfilled": 38, "observed": 45],
                               "cohorts": ["off": ["cost_usd": 212.4, "tokens": 1, "api_calls": 1380, "sessions": 38, "cost_per_call": 0.1539, "cost_per_session": 5.59, "tokens_per_call": 6449.0],
                                           "on": ["cost_usd": 198.7, "tokens": 1, "api_calls": 1495, "sessions": 41, "cost_per_call": 0.1329, "cost_per_session": 4.85, "tokens_per_call": 6087.0],
                                           "mixed": ["cost_usd": 0, "tokens": 0, "api_calls": 0, "sessions": 0, "cost_per_call": NSNull(), "cost_per_session": NSNull(), "tokens_per_call": NSNull()],
                                           "unknown": ["cost_usd": 0, "tokens": 0, "api_calls": 0, "sessions": 0]],
                               "comparison": ["comparable": true, "reason": NSNull(), "min_sessions": 10, "min_calls": 200, "cost_per_call_change": -0.137,
                                              "cost_per_session_change": -0.132, "tokens_per_call_change": -0.056],
                               "paired_roots": [["agent_root": "zimmer", "off": ["cost_usd": 1, "sessions": 3, "cost_per_call": 0.2], "on": ["cost_usd": 1, "sessions": 4, "cost_per_call": 0.1], "cost_per_call_change": -0.5]]]],
            "top_sessions": [["session_id": 1042, "cost_usd": 23.81, "tokens": 1_204_331, "api_calls": 212, "title": "CarPlay"]],
            "unpriced_models": ["gpt-5.2-codex"],
            "burn_rates": [["harness": "claude_code", "model": "claude-opus-4-5", "usd_per_minute": 0.212, "usd_per_hour": 12.72,
                            "sample_session_count": 20, "sample_minutes": 1840.5, "computed_at": "2026-10-11T00:00:00Z"]],
            "pricing": ["note": "x"],
        ]) }])

        let costs = try await api.costs(.days(7), scope: .fleet)

        XCTAssertEqual(costs.totals.apiCalls, 2_195)
        XCTAssertEqual(costs.totals.tokens, 16_000_000)
        XCTAssertEqual(costs.totals.adhocShare, 14.3 / 369.6, accuracy: 0.0001)
        XCTAssertEqual(costs.coverage?.headline, "Re-scanning history — 62%", "a running sweep after a finished one is a re-scan")
        XCTAssertEqual(costs.coverage?.directoriesTotal, 212)
        XCTAssertNotNil(costs.coverage?.coversSince)
        XCTAssertEqual(costs.breakdown.map(\.component), ["cache read", "output"])
        XCTAssertEqual(costs.days.first?.apiCalls, 310)
        XCTAssertEqual(costs.days.first?.roots.first?.label, "zimmer")
        XCTAssertEqual(costs.days.first?.models.first?.costUSD ?? 0, 50.0, accuracy: 0.001)
        XCTAssertEqual(costs.agentRoots.first?.details.map(\.label), ["skills"], "the root's context-feature split")
        XCTAssertEqual(costs.agentRoots.first?.perCallUSD ?? 0, 201.4 / 1204, accuracy: 0.0001)
        XCTAssertEqual(costs.threadKinds.map(\.label), ["main", "subagent"])
        XCTAssertEqual(costs.runtimes.last?.tokens, 402_000, "codex carries tokens and no dollars")
        XCTAssertEqual(costs.adhocSources.first?.label, "session_title")
        XCTAssertEqual(costs.features?.coverage ?? 0, 0.192, accuracy: 0.0001)
        XCTAssertEqual(costs.features?.residualCostUSD ?? 0, 294.1, accuracy: 0.001)
        let experiment = try XCTUnwrap(costs.experiments.first)
        XCTAssertEqual(experiment.currentValue, true)
        XCTAssertEqual(experiment.off.sessions, 38)
        XCTAssertNil(experiment.mixed.costPerCall)
        XCTAssertTrue(experiment.comparison.comparable)
        XCTAssertEqual(experiment.comparison.costPerCallChange ?? 0, -0.137, accuracy: 0.0001)
        XCTAssertEqual(experiment.pairedRoots.first?.agentRoot, "zimmer")
        XCTAssertEqual(experiment.taggedBackfilled, 38)
        XCTAssertEqual(costs.unpricedModels, ["gpt-5.2-codex"])
        XCTAssertEqual(costs.burnRates.first?.usdPerHour ?? 0, 12.72, accuracy: 0.001)
        XCTAssertEqual(costs.burnRates.first?.sampleSessionCount, 20)
        XCTAssertEqual(costs.totalUSD, 369.6, accuracy: 0.001)
    }

    func testTheTriggerPageReadsItsClassArtifactsAndWindows() throws {
        let trigger = try ZimmerJSON.decoder.decode(TriggerSummary.self, from: Data(#"""
        {"id": 5, "name": "Nightly", "status": "enabled", "scheduling_class": null, "effective_scheduling_class": "spot", "precedence": 40,
         "coalesce_window_seconds": null, "effective_coalesce_window_seconds": 60, "coalesce_window_inert": true,
         "skip_if_pending_session": true, "skip_if_pending_session_inert": true, "missed_fire_count": 2, "first_missed_fire_at": "2026-10-10T02:00:00Z",
         "mcp_servers": ["github", "linear"], "catalog_skills": ["open-pr"], "catalog_hooks": [], "catalog_plugins": ["zimmer-ops"],
         "unresolved_catalog_references": {"mcp_servers": {"linear": "2026-10-09T00:00:00Z"}},
         "prompt_template": "Triage {{text|untrusted}} from {{author}} at {{link}} on {{date}}; {{not_a_variable}} stays"}
        """#.utf8))

        XCTAssertNil(trigger.schedulingClass)
        XCTAssertEqual(trigger.effectiveSchedulingClass, "spot")
        XCTAssertEqual(trigger.precedence, 40)
        XCTAssertEqual(trigger.effectiveCoalesceWindowSeconds, 60)
        XCTAssertTrue(trigger.coalesceWindowInert)
        XCTAssertTrue(trigger.skipIfPendingSessionInert)
        XCTAssertNotNil(trigger.firstMissedFireAt)
        XCTAssertEqual(trigger.mcpServers, ["github", "linear"])
        XCTAssertEqual(trigger.catalogPlugins, ["zimmer-ops"])
        XCTAssertTrue(trigger.catalogReferenceUnresolved("mcp_servers", "linear"))
        XCTAssertFalse(trigger.catalogReferenceUnresolved("mcp_servers", "github"))
        XCTAssertEqual(trigger.promptVariables, ["link", "text", "author"], "the form's order; {{date}} fills itself and an unknown name is not a variable")
        XCTAssertEqual(TriggerSummary.placeholder(for: "repo"), "e.g. tadasant/zimmer")
        XCTAssertEqual(TriggerSummary(id: 1, name: "x", status: "enabled", promptTemplate: "Sweep on {{date}}").promptVariables, [])
    }

    func testRunNowSendsTheVariablesItWasGiven() async throws {
        let (api, transport) = client([
            { _ in Fixtures.json(201, ["trigger": ["id": 7], "session": ["id": 2002], "message": "Fired"]) },
            { _ in Fixtures.json(201, ["trigger": ["id": 7], "session": ["id": 2003], "message": "Fired"]) },
        ])

        _ = try await api.invokeTrigger(7, variables: ["text": "Review PR 42", "link": "", "author": "Jane"])
        _ = try await api.invokeTrigger(7)

        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: transport.sent[0].body ?? Data()) as? [String: Any])
        XCTAssertEqual(first["variables"] as? [String: String], ["text": "Review PR 42", "author": "Jane"], "a blank field is left out, as the form's empty input is")
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: transport.sent[1].body ?? Data()) as? [String: Any])
        XCTAssertTrue(second.isEmpty, "nothing to fill in sends the bare request")
    }

    func testTheFixtureFillsATemplateWithTheVariablesItIsRun() async throws {
        let fake = FakeZimmerAPI()
        let invoked = try await fake.invokeTrigger(7, variables: ["text": "Review PR 42", "author": "Jane"])
        let session = try await fake.session(try XCTUnwrap(invoked.sessionID))
        let variables = await fake.triggerVariables[7]
        XCTAssertEqual(variables, ["text": "Review PR 42", "author": "Jane"])
        XCTAssertTrue(session.session.prompt?.hasPrefix("Triage this thread: Review PR 42 from Jane at . Reply") ?? false, "filled as the server interpolates: a missing variable reads as nothing")
        XCTAssertFalse(session.session.prompt?.contains("{{") ?? true, "{{date}} filled itself")
        let degraded = try await FakeZimmerAPI(degraded: true).health()
        XCTAssertFalse(degraded.banners.isEmpty)
        let quiet = try await fake.health()
        XCTAssertTrue(quiet.banners.isEmpty)
        XCTAssertEqual(quiet.cron?.keys.count, 6)
        let fleet = try await fake.costs(.days(7), scope: .fleet)
        XCTAssertFalse(fleet.burnRates.isEmpty)
        XCTAssertFalse(fleet.experiments.isEmpty)
        let root = try await fake.costs(.days(7), scope: .agentRoot("zimmer"))
        XCTAssertTrue(root.burnRates.isEmpty, "burn rates and experiments are the fleet page's only")
        XCTAssertTrue(root.experiments.isEmpty)
    }

    func testTheFixtureRefusesWhatTheServerRefuses() async throws {
        let fake = FakeZimmerAPI()
        await XCTAssertThrowsAsync(try await fake.dismissNotification(91), "an unread notification is not dismissed")
        _ = try await fake.markNotificationRead(91)
        try await fake.dismissNotification(91)
        let unread = try await fake.unreadNotificationCount()
        XCTAssertEqual(unread, 1)
        let disabled = try await fake.invokeTrigger(6)
        XCTAssertNotNil(disabled.sessionID, "a disabled trigger can still be fired by hand, as on the server")
        let invoked = try await fake.invokeTrigger(5)
        XCTAssertTrue(invoked.started)
    }
}
