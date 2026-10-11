import XCTest
@testable import ZimmerKit

/// Photos and files sent with a message.
final class AttachmentsTests: XCTestCase {
    private func client(_ handlers: [ScriptedTransport.Handler]) -> (ZimmerHTTPClient, ScriptedTransport) {
        let transport = ScriptedTransport(handlers)
        return (ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport), transport)
    }

    private func body(_ request: HTTPRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])
    }

    private let photo = MessageAttachment(filename: "screen.jpg", mediaType: "image/jpeg", data: Data([0xFF, 0xD8, 0xFF]))
    private let log = MessageAttachment(filename: "deploy.log", mediaType: "text/plain", data: Data("failed at step 3\n".utf8))

    func testAFollowUpSendsEachAttachmentInlineAsBase64() async throws {
        let (api, transport) = client([{ _ in Fixtures.json(200, ["message": "Follow-up prompt sent"]) }])

        let result = try await api.followUp(9, prompt: "What broke?", attachments: [photo, log], now: false)

        XCTAssertEqual("\(transport.sent[0].method) \(transport.sent[0].url.path)", "POST /api/v1/sessions/9/follow_up")
        let sent = try body(transport.sent[0])
        XCTAssertEqual(sent["prompt"] as? String, "What broke?")
        XCTAssertNil(sent["force_immediate"])
        let attachments = try XCTUnwrap(sent["attachments"] as? [[String: String]])
        XCTAssertEqual(attachments, [
            ["filename": "screen.jpg", "media_type": "image/jpeg", "data": "/9j/"],
            ["filename": "deploy.log", "media_type": "text/plain", "data": Data("failed at step 3\n".utf8).base64EncodedString()],
        ])
        XCTAssertFalse(result.queued)
    }

    func testSendNowWithAttachmentsAsksForImmediateDelivery() async throws {
        let (api, transport) = client([{ _ in Fixtures.json(200, ["message": "Follow-up prompt sent immediately"]) }])

        let result = try await api.followUp(9, prompt: "Stop and look", attachments: [photo], now: true)

        XCTAssertEqual(try body(transport.sent[0])["force_immediate"] as? Bool, true)
        XCTAssertFalse(result.queued)
    }

    func testAQueuedFollowUpSaysSo() async throws {
        let (api, _) = client([{ _ in Fixtures.json(202, ["message": "Message queued", "enqueued_message": ["id": 1, "position": 1]]) }])
        let result = try await api.followUp(9, prompt: "Later", attachments: [log], now: false)
        XCTAssertTrue(result.queued)
    }

    func testAnImageOverTheServersLimitIsCaughtBeforeSending() {
        let big = MessageAttachment(filename: "huge.png", mediaType: "image/png", data: Data(count: MessageAttachment.maxImageBytes + 1))
        XCTAssertEqual(big.problem, "huge.png is over the 10 MB image limit.")
        XCTAssertNil(MessageAttachment(filename: "huge.log", mediaType: "text/plain", data: Data(count: MessageAttachment.maxImageBytes + 1)).problem,
                     "files have a far larger limit than images")
        XCTAssertTrue(photo.isImage)
        XCTAssertFalse(log.isImage)
        XCTAssertFalse(MessageAttachment(filename: "x.heic", mediaType: "image/heic", data: Data([1])).isImage, "HEIC is not one the server keeps as an image")
    }

    func testTheFakeDeliversAndRecordsAttachments() async throws {
        let api = FakeZimmerAPI()
        _ = try await api.followUp(1038, prompt: "See attached", attachments: [photo, log], now: false)
        let recorded = await api.sentAttachments[1038]
        XCTAssertEqual(recorded?.last?.map(\.filename), ["screen.jpg", "deploy.log"])
        let last = try await api.conversation(1038).messages.last
        XCTAssertEqual(last?.content, "See attached\n\n📎 screen.jpg, deploy.log")
    }
}
