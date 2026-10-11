import Foundation

/// The web UI's pages beyond the board: the notifications inbox, triggers (list, turn on or
/// off, invoke), costs and health — each read-only except where the web UI's own buttons
/// write, and each open to the app's token for exactly those actions.
public protocol OperationsAPI: Sendable {
    func notifications() async throws -> [InboxNotification]
    /// How many notifications are unread — the tab's badge.
    func unreadNotificationCount() async throws -> Int
    func markNotificationRead(_ id: Int) async throws -> InboxNotification
    func markAllNotificationsRead() async throws
    /// Dismiss a read notification (an unread one is refused).
    func dismissNotification(_ id: Int) async throws
    func dismissAllReadNotifications() async throws
    func triggers() async throws -> [TriggerSummary]
    /// Turn a trigger on or off — the web UI's toggle.
    func toggleTrigger(_ id: Int) async throws -> TriggerSummary
    /// Fire a trigger now, as the web UI's Invoke button does.
    func invokeTrigger(_ id: Int) async throws -> TriggerInvocation
    /// The Costs page over the last `days` days.
    func costs(days: Int) async throws -> CostSnapshot
    func health() async throws -> HealthReport
}

// `ZimmerHTTPClient: ZimmerAPI`, which refines `OperationsAPI`.
extension ZimmerHTTPClient {
    public func notifications() async throws -> [InboxNotification] {
        let response: NotificationsResponse = try await get("/api/v1/notifications", query: ["per_page": "100"])
        return response.notifications
    }

    public func unreadNotificationCount() async throws -> Int {
        let response: BadgeResponse = try await get("/api/v1/notifications/badge")
        return response.pending_count ?? 0
    }

    public func markNotificationRead(_ id: Int) async throws -> InboxNotification {
        let response: NotificationResponse = try await patch("/api/v1/notifications/\(id)/mark_read", json: [:])
        return response.notification
    }

    public func markAllNotificationsRead() async throws {
        _ = try await perform(method: "PATCH", path: "/api/v1/notifications/mark_all_read", query: [:], body: Data("{}".utf8))
    }

    public func dismissNotification(_ id: Int) async throws {
        _ = try await perform(method: "DELETE", path: "/api/v1/notifications/\(id)/dismiss", query: [:], body: nil)
    }

    public func dismissAllReadNotifications() async throws {
        _ = try await perform(method: "DELETE", path: "/api/v1/notifications/dismiss_all_read", query: [:], body: nil)
    }

    public func triggers() async throws -> [TriggerSummary] {
        let response: TriggersResponse = try await get("/api/v1/triggers", query: ["per_page": "100"])
        return response.triggers
    }

    public func toggleTrigger(_ id: Int) async throws -> TriggerSummary {
        let response: TriggerResponse = try await post("/api/v1/triggers/\(id)/toggle", json: [:])
        return response.trigger
    }

    public func invokeTrigger(_ id: Int) async throws -> TriggerInvocation {
        let response: TriggerInvokeResponse = try await post("/api/v1/triggers/\(id)/invoke", json: [:])
        return TriggerInvocation(sessionID: response.session?.id, message: response.message ?? "Invoked")
    }

    public func costs(days: Int) async throws -> CostSnapshot {
        try await get("/api/v1/costs", query: ["days": String(days)])
    }

    public func health() async throws -> HealthReport {
        let response = try await perform(method: "GET", path: "/api/v1/health", query: [:], body: nil)
        return try HealthReport.parse(response.body)
    }
}
