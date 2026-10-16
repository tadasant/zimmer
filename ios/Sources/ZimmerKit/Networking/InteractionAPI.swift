import Foundation

/// Answering what an MCP server asked, and forking a session at a message. Both were
/// browser-only until the server listed a session's open prompts and gave each conversation
/// message the index `fork` takes. Answering is open to the app's token only on a grant that
/// acts as you; a relay-only one gets a 403 that says so.
public protocol InteractionAPI: Sendable {
    /// The session's prompts still waiting on an answer, oldest first.
    func pendingElicitations(_ id: Int) async throws -> [PendingElicitation]
    /// Answer one. `content` is the form's JSON object, sent only with `accept`.
    func answerElicitation(_ elicitation: Int, answer: ElicitationAnswer, content: String?) async throws
    /// A new session that is this one up to and including the message at `transcriptIndex`,
    /// waiting for its next prompt.
    func fork(_ id: Int, at transcriptIndex: Int) async throws -> SessionSummary
}

// `ZimmerHTTPClient: ZimmerAPI`, which refines `InteractionAPI`.
extension ZimmerHTTPClient {
    public func pendingElicitations(_ id: Int) async throws -> [PendingElicitation] {
        let segment = ZimmerPathComponent(String(id))
        let response: ElicitationsResponse = try await get("/api/v1/sessions/\(segment)/elicitations")
        return response.pending
    }

    public func answerElicitation(_ elicitation: Int, answer: ElicitationAnswer, content: String?) async throws {
        var json: [String: Any] = ["action_type": answer.rawValue]
        if answer == .accept, let content { json["content"] = content }
        let _: ElicitationAnswerResponse = try await patch("/api/v1/elicitations/\(elicitation)/respond", json: json)
    }

    public func fork(_ id: Int, at transcriptIndex: Int) async throws -> SessionSummary {
        let segment = ZimmerPathComponent(String(id))
        let response: SessionEnvelope = try await post("/api/v1/sessions/\(segment)/fork", json: ["message_index": transcriptIndex])
        return response.session
    }
}

struct ElicitationAnswerResponse: Decodable {
    let action: String?
}
