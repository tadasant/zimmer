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

    private let photo = MessageAttachment(filename: "screen.jpg", mediaType: "image/jpeg", data: Data([0xFF, 0xD8, 0xFF, 0xE0]))
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
            ["filename": "screen.jpg", "media_type": "image/jpeg", "data": "/9j/4A=="],
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

    func testAnImageIsAnImageByItsBytesAsTheServerReadsThem() {
        XCTAssertTrue(photo.isImage)
        XCTAssertFalse(log.isImage)
        XCTAssertTrue(MessageAttachment(filename: "shot", mediaType: "application/octet-stream", data: Data([0x89, 0x50, 0x4E, 0x47, 0, 0])).isImage,
                      "a PNG with no extension is still an image")
        XCTAssertTrue(MessageAttachment(filename: "a.gif", mediaType: "", data: Data("GIF89a".utf8)).isImage)
        XCTAssertTrue(MessageAttachment(filename: "a.webp", mediaType: "", data: Data("RIFF\0\0\0\0WEBPVP8 ".utf8)).isImage)
        XCTAssertFalse(MessageAttachment(filename: "fake.png", mediaType: "image/png", data: Data("not a png".utf8)).isImage,
                       "a .png whose bytes are not one goes as a file")
        XCTAssertFalse(MessageAttachment(filename: "x.heic", mediaType: "image/heic", data: Data([0, 0, 0, 0x18, 0x66, 0x74])).isImage,
                       "HEIC is not one the server keeps as an image")
    }

    func testAnImageOverTheServersLimitIsCaughtBeforeSending() {
        var pngBytes = Data([0x89, 0x50, 0x4E, 0x47])
        pngBytes.append(Data(count: MessageAttachment.maxImageBytes))
        let big = MessageAttachment(filename: "huge.png", mediaType: "image/png", data: pngBytes)
        XCTAssertEqual(big.problem, "huge.png is over the 10 MB image limit.")
        XCTAssertNil(MessageAttachment(filename: "huge.log", mediaType: "text/plain", data: Data(count: MessageAttachment.maxImageBytes + 1)).problem,
                     "files have a far larger limit than images")
    }

    func testAMessageKeepsToTheServersCountAndTotal() {
        let tenMB = Data(count: 10 * 1024 * 1024)
        let seven = (1...7).map { MessageAttachment(filename: "f\($0).bin", mediaType: "application/octet-stream", data: tenMB) }
        XCTAssertNil(MessageAttachment.refusal(adding: log, to: seven))
        let eighth = MessageAttachment(filename: "f8.bin", mediaType: "application/octet-stream", data: tenMB)
        XCTAssertEqual(MessageAttachment.refusal(adding: eighth, to: seven), "f8.bin would take this message over its 75 MB of attachments.")
        let twenty = (1...20).map { MessageAttachment(filename: "n\($0).txt", mediaType: "text/plain", data: Data("x".utf8)) }
        XCTAssertEqual(MessageAttachment.refusal(adding: log, to: twenty), "A message carries at most 20 attachments.")
        XCTAssertEqual(MessageAttachment.refusal(adding: MessageAttachment(filename: "e.txt", mediaType: "text/plain", data: Data()), to: []), "e.txt is empty.")
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
