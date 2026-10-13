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
        XCTAssertEqual(window["from"], "2026-08-01T00:00:00.000-07:00")
        XCTAssertEqual(window["to"], "2026-08-03T23:59:59.999-07:00")
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
