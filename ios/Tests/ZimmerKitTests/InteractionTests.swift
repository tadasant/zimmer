import XCTest
@testable import ZimmerKit

/// Slice 6: answering an MCP server's prompt, and forking at a message.
final class InteractionTests: XCTestCase {
    private func client(_ handlers: [ScriptedTransport.Handler]) -> (ZimmerHTTPClient, ScriptedTransport) {
        let transport = ScriptedTransport(handlers)
        return (ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport), transport)
    }

    private func body(_ request: HTTPRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])
    }

    func testAPromptIsReadIntoAFormInTheBannersOrder() async throws {
        let (api, transport) = client([{ _ in Fixtures.json(200, ["elicitations": [[
            "id": 71, "request_id": "req-1", "mode": "form", "message": "Send it?",
            "tool_name": "send_email", "context": "To the team", "expires_at": "2026-10-11T18:00:00Z",
            "field_order": ["send_to", "count", "urgent", "tone", "ratio", "notes"],
            "requested_schema": [
                "type": "object",
                "required": ["send_to"],
                "properties": [
                    "notes": ["type": "array"],
                    "ratio": ["type": "number", "default": 0.5],
                    "tone": ["type": "string", "title": "Tone", "enum": ["warm", "dry"]],
                    "urgent": ["type": "boolean", "description": "Page them"],
                    "count": ["type": "integer", "default": 3],
                    "send_to": ["type": "string"],
                ],
            ],
        ]]]) }])

        let prompts = try await api.pendingElicitations(9)

        XCTAssertEqual(transport.sent[0].url.path, "/api/v1/sessions/9/elicitations")
        let prompt = try XCTUnwrap(prompts.first)
        XCTAssertEqual(prompt.id, 71)
        XCTAssertEqual(prompt.toolName, "send_email")
        XCTAssertNotNil(prompt.expiresAt)
        XCTAssertEqual(prompt.form.fields.map(\.key), ["send_to", "count", "urgent", "tone", "ratio", "notes"])
        XCTAssertEqual(prompt.form.fields.map(\.kind), [.text, .number(integer: true), .toggle, .choice(["warm", "dry"]), .number(integer: false), .text])
        XCTAssertEqual(prompt.form.fields.map(\.title), ["Send to", "Count", "Urgent", "Tone", "Ratio", "Notes"])
        XCTAssertEqual(prompt.form.fields.map(\.required), [true, false, false, false, false, false])
        XCTAssertEqual(prompt.form.fields[1].placeholder, "3")
        XCTAssertEqual(prompt.form.fields[2].detail, "Page them")
    }

    func testAFieldTheServerDidNotOrderStillShowsAfterTheOrderedOnes() {
        let schema = try! JSONDecoder().decode(RequestedSchema.self, from: Data(#"{"properties":{"b":{"type":"string"},"a":{"type":"string"},"c":{"type":"string"}}}"#.utf8))
        XCTAssertEqual(ElicitationForm.make(schema: schema, order: ["c"]).fields.map(\.key), ["c", "a", "b"])
        XCTAssertEqual(ElicitationForm.make(schema: nil, order: ["c"]).fields, [])
    }

    func testAnAcceptCarriesEveryFieldAsTheBannerSendsIt() throws {
        let form = ElicitationForm(fields: [
            .init(key: "to", title: "To", kind: .text, required: true),
            .init(key: "count", title: "Count", kind: .number(integer: true)),
            .init(key: "ratio", title: "Ratio", kind: .number(integer: false)),
            .init(key: "urgent", title: "Urgent", kind: .toggle),
            .init(key: "tone", title: "Tone", kind: .choice(["warm", "dry"])),
        ])

        let content = try form.content(from: ["to": " team@ ", "count": "-4", "ratio": ""], toggles: [:])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])

        XCTAssertEqual(object["to"] as? String, "team@")
        XCTAssertEqual(object["count"] as? Int, -4)
        XCTAssertEqual(try form.content(from: ["to": "x", "ratio": "1,5"], toggles: [:]).contains(#""ratio":1.5"#), true, "a comma decimal is read")
        XCTAssertTrue(object["ratio"] is NSNull)
        XCTAssertEqual(object["urgent"] as? Bool, false)
        XCTAssertTrue(object["tone"] is NSNull)
    }

    func testAnAcceptMissingARequiredFieldOrANumberIsRefusedByName() {
        let form = ElicitationForm(fields: [
            .init(key: "to", title: "To", kind: .text, required: true),
            .init(key: "count", title: "Count", kind: .number(integer: true)),
        ])
        XCTAssertThrowsError(try form.content(from: ["count": "2"], toggles: [:])) {
            XCTAssertEqual($0 as? ElicitationFormError, .missing("To"))
        }
        XCTAssertThrowsError(try form.content(from: ["to": "x", "count": "2.5"], toggles: [:])) {
            XCTAssertEqual(($0 as? ElicitationFormError)?.message, "Count needs a number.")
        }
    }

    func testAnAnswerSendsContentOnlyWithAccept() async throws {
        let answered: ScriptedTransport.Handler = { _ in Fixtures.json(200, ["action": "accept", "_meta": [:]]) }
        let (api, transport) = client([answered, answered])

        try await api.answerElicitation(71, answer: .accept, content: #"{"to":"x"}"#)
        try await api.answerElicitation(71, answer: .decline, content: #"{"to":"x"}"#)

        XCTAssertEqual(transport.sent.map { "\($0.method) \($0.url.path)" }, [
            "PATCH /api/v1/elicitations/71/respond", "PATCH /api/v1/elicitations/71/respond",
        ])
        XCTAssertEqual(try body(transport.sent[0]) as? [String: String], ["action_type": "accept", "content": #"{"to":"x"}"#])
        XCTAssertEqual(try body(transport.sent[1]) as? [String: String], ["action_type": "decline"])
    }

    func testARelayOnlySignInIsToldWhyItCannotAnswer() async throws {
        let (api, _) = client([{ _ in Fixtures.json(403, ["error": "Forbidden", "message": "This sign-in may read prompts but not answer them; sign in again and allow acting as you"]) }])

        do {
            try await api.answerElicitation(71, answer: .accept, content: nil)
            XCTFail("expected a refusal")
        } catch let ZimmerError.http(status, message) {
            XCTAssertEqual(status, 403)
            XCTAssertEqual(message, "This sign-in may read prompts but not answer them; sign in again and allow acting as you")
        }
    }

    func testForkSendsTheMessagesTranscriptIndex() async throws {
        let (api, transport) = client([
            { _ in Fixtures.json(200, ["messages": [
                ["role": "user", "content": "Ship it?", "transcript_index": 1],
                ["role": "assistant", "content": "Merge?", "transcript_index": 4],
            ], "total": 2, "truncated": false]) },
            { _ in Fixtures.json(201, ["session": ["id": 77, "status": "needs_input", "title": "Fork of x"], "message": "Session forked successfully"]) },
        ])

        let conversation = try await api.conversation(9)
        XCTAssertEqual(conversation.messages.map(\.transcriptIndex), [1, 4])
        let forked = try await api.fork(9, at: try XCTUnwrap(conversation.messages.last?.transcriptIndex))

        XCTAssertEqual("\(transport.sent[1].method) \(transport.sent[1].url.path)", "POST /api/v1/sessions/9/fork")
        XCTAssertEqual(try body(transport.sent[1])["message_index"] as? Int, 4)
        XCTAssertEqual(forked.id, 77)
    }

    func testTheFakeAnswersAndForksAsTheServerDoes() async throws {
        let api = FakeZimmerAPI()
        let prompts = try await api.pendingElicitations(1035)
        XCTAssertEqual(prompts.map(\.id), [71])

        try await api.answerElicitation(71, answer: .accept, content: "{}")
        let left = try await api.pendingElicitations(1035)
        XCTAssertTrue(left.isEmpty)

        let history = try await api.conversation(1038).messages
        let forked = try await api.fork(1038, at: history[1].transcriptIndex ?? -1)
        let copied = try await api.conversation(forked.id).messages
        XCTAssertEqual(forked.status, .needsInput)
        XCTAssertEqual(copied.map(\.content), history.prefix(2).map(\.content))
    }
}
