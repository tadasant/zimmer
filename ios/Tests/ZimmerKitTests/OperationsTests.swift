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

        let costs = try await api.costs(days: 7)

        XCTAssertEqual(URLComponents(url: transport.sent[0].url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "7")
        XCTAssertEqual(costs.totalUSD, 369.6, accuracy: 0.001)
        XCTAssertEqual(costs.days.first?.costUSD ?? 0, 53.4, accuracy: 0.001)
        XCTAssertEqual(costs.agentRoots.map(\.label), ["zimmer", "other (3)"])
        XCTAssertEqual(costs.models.first?.label, "opus")
        XCTAssertEqual(costs.topSessions.first?.sessionID, 1042)
        XCTAssertNotNil(costs.from)
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
        await XCTAssertThrowsAsync(try await fake.invokeTrigger(6), "a disabled trigger is not invoked")
        let invoked = try await fake.invokeTrigger(5)
        XCTAssertNotNil(invoked.sessionID)
    }
}
