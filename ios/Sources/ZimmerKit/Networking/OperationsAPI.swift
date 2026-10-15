import Foundation

/// The web UI's pages beyond the board: the notifications inbox, triggers (list, read one, turn
/// on or off, invoke), costs and health — each read-only except where the web UI's own buttons
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
    /// One trigger's page: everything the list carries, and the sessions it last made.
    func trigger(_ id: Int) async throws -> TriggerDetail
    /// Turn a trigger on or off — the web UI's toggle.
    func toggleTrigger(_ id: Int) async throws -> TriggerSummary
    /// Fire a trigger now, as the web UI's Run Now does, with values for the `{{variables}}`
    /// its template names (`variables` in the request; a variable left out interpolates empty).
    func invokeTrigger(_ id: Int, variables: [String: String]) async throws -> TriggerInvocation
    /// The Costs page over `window`, narrowed to `scope`.
    func costs(_ window: CostWindow, scope: CostScope) async throws -> CostSnapshot
    func health() async throws -> HealthReport
}

extension OperationsAPI {
    /// A run with nothing to fill in: a template with no variables, or every one left blank.
    public func invokeTrigger(_ id: Int) async throws -> TriggerInvocation {
        try await invokeTrigger(id, variables: [:])
    }
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

    public func trigger(_ id: Int) async throws -> TriggerDetail {
        try await get("/api/v1/triggers/\(id)")
    }

    public func toggleTrigger(_ id: Int) async throws -> TriggerSummary {
        let response: TriggerResponse = try await post("/api/v1/triggers/\(id)/toggle", json: [:])
        return response.trigger
    }

    public func invokeTrigger(_ id: Int, variables: [String: String]) async throws -> TriggerInvocation {
        // Blank fields are left out, as the web form's empty inputs amount to: the server fills
        // an omitted variable with an empty string either way.
        let filled = variables.filter { !$0.value.isEmpty }
        let body = try JSONSerialization.data(withJSONObject: filled.isEmpty ? [:] : ["variables": filled])
        // 409 and 422 name the session in the way, which the person wants to open; a 429 (burst
        // suppressed) is an error like any other.
        let raw = try await perform(method: "POST", path: "/api/v1/triggers/\(id)/invoke", query: [:], body: body, accepting: [409, 422])
        let response = try? ZimmerJSON.decoder.decode(TriggerInvokeResponse.self, from: raw.body)
        let message = response?.message ?? "Invoked"
        switch raw.statusCode {
        case 409: return TriggerInvocation(outcome: .pendingSession, sessionID: response?.session?.id, message: message)
        case 422:
            // A plain 422 with no session to show (an unknown agent root, say) is a refusal.
            guard let session = response?.session?.id else { throw ZimmerError.http(status: 422, message: message) }
            return TriggerInvocation(outcome: .notReusable, sessionID: session, message: message)
        default:
            return TriggerInvocation(outcome: response?.burst_notice == true ? .burstNotice : .started,
                                     sessionID: response?.session?.id, message: message)
        }
    }

    public func costs(_ window: CostWindow, scope: CostScope) async throws -> CostSnapshot {
        let response = try await perform(method: "GET", path: "/api/v1/costs", query: window.query().merging(scope.query) { _, scoped in scoped }, body: nil)
        return try CostSnapshot.parse(response.body)
    }

    public func health() async throws -> HealthReport {
        let response = try await perform(method: "GET", path: "/api/v1/health", query: [:], body: nil)
        return try HealthReport.parse(response.body)
    }
}
