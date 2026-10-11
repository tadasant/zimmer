import Foundation

/// The parts of the web UI's session page beyond the session itself: its queue of messages,
/// its logs, and the subagents it ran. These routes are on controllers other than
/// `SessionsController`, each open to the app's token for exactly these actions
/// (`accepts_native_app_tokens only:`): reading and managing the queue (never adding to it —
/// the app queues through `follow_up`), and reading logs and subagent transcripts.
public protocol SessionDetailExtrasAPI: Sendable {
    /// The messages waiting for the turn in flight to end, in delivery order.
    func queue(_ id: Int) async throws -> [QueuedMessage]
    /// Rewrite a queued message. Recorded as your message when the app acts on your behalf.
    func editQueued(_ id: Int, message: Int, content: String) async throws -> QueuedMessage
    func deleteQueued(_ id: Int, message: Int) async throws
    /// Move a queued message to `position` (1 is next).
    func moveQueued(_ id: Int, message: Int, to position: Int) async throws -> QueuedMessage
    /// Deliver a queued message now, ending the turn in flight — the web UI's queue "Send now".
    func sendQueuedNow(_ id: Int, message: Int) async throws
    /// One page of the session's log, newest first, without the raw CLI output — the web
    /// UI's *Show Logs*.
    func logs(_ id: Int, page: Int) async throws -> LogPage
    func subagentTranscripts(_ id: Int) async throws -> [SubagentTranscriptSummary]
    /// A subagent's transcript, read into messages.
    func subagentTranscript(_ id: Int, transcript: Int) async throws -> [ConversationMessage]
    /// Remove `uncle` as an additional senior of session `junior` — the hierarchy panel's
    /// detach. Spawn parents are untouched.
    func detachUncle(_ junior: Int, uncle: Int) async throws
}

// `ZimmerHTTPClient: ZimmerAPI`, which refines `SessionDetailExtrasAPI`.
extension ZimmerHTTPClient {
    public func queue(_ id: Int) async throws -> [QueuedMessage] {
        let segment = ZimmerPathComponent(String(id))
        let response: QueuedMessagesResponse = try await get("/api/v1/sessions/\(segment)/enqueued_messages", query: ["status": "pending", "per_page": "100"])
        return response.enqueued_messages.sorted { $0.position < $1.position }
    }

    public func editQueued(_ id: Int, message: Int, content: String) async throws -> QueuedMessage {
        let segment = ZimmerPathComponent(String(id))
        let response: QueuedMessageResponse = try await patch("/api/v1/sessions/\(segment)/enqueued_messages/\(message)", json: ["content": content])
        return response.enqueued_message
    }

    public func deleteQueued(_ id: Int, message: Int) async throws {
        let segment = ZimmerPathComponent(String(id))
        _ = try await perform(method: "DELETE", path: "/api/v1/sessions/\(segment)/enqueued_messages/\(message)", query: [:], body: nil)
    }

    public func moveQueued(_ id: Int, message: Int, to position: Int) async throws -> QueuedMessage {
        let segment = ZimmerPathComponent(String(id))
        let response: QueuedMessageResponse = try await patch("/api/v1/sessions/\(segment)/enqueued_messages/\(message)/reorder", json: ["position": position])
        return response.enqueued_message
    }

    public func sendQueuedNow(_ id: Int, message: Int) async throws {
        let segment = ZimmerPathComponent(String(id))
        let _: MessageEnvelope = try await post("/api/v1/sessions/\(segment)/enqueued_messages/\(message)/interrupt", json: [:])
    }

    public func logs(_ id: Int, page: Int) async throws -> LogPage {
        let segment = ZimmerPathComponent(String(id))
        let response: LogsResponse = try await get("/api/v1/sessions/\(segment)/logs", query: ["page": String(page), "per_page": "50", "exclude_level": "verbose"])
        let pages = response.pagination?.total_pages ?? 1
        return LogPage(entries: response.logs, hasMore: page < pages)
    }

    public func detachUncle(_ junior: Int, uncle: Int) async throws {
        let segment = ZimmerPathComponent(String(junior))
        _ = try await perform(method: "DELETE", path: "/api/v1/sessions/\(segment)/uncle_links/\(uncle)", query: [:], body: nil)
    }

    public func subagentTranscripts(_ id: Int) async throws -> [SubagentTranscriptSummary] {
        let segment = ZimmerPathComponent(String(id))
        let response: SubagentTranscriptsResponse = try await get("/api/v1/sessions/\(segment)/subagent_transcripts", query: ["per_page": "100"])
        return response.subagent_transcripts
    }

    public func subagentTranscript(_ id: Int, transcript: Int) async throws -> [ConversationMessage] {
        let segment = ZimmerPathComponent(String(id))
        let response: SubagentTranscriptResponse = try await get("/api/v1/sessions/\(segment)/subagent_transcripts/\(transcript)", query: ["include_transcript": "true"])
        return SubagentTranscriptText.messages(fromJSONL: response.subagent_transcript.transcript ?? "")
    }
}
