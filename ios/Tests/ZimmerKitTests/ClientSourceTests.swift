import XCTest
@testable import ZimmerKit

/// The headers behind Zimmer's turn-source note: which client sent a request, and — when
/// the app knows — how the words were produced.
final class ClientSourceTests: XCTestCase {
    private func client(_ handlers: [ScriptedTransport.Handler], source: ClientSource = .app(version: "1.4.2")) -> (ZimmerHTTPClient, ScriptedTransport) {
        let transport = ScriptedTransport(handlers)
        let api = ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport, source: source)
        return (api, transport)
    }

    private let sent: ScriptedTransport.Handler = { _ in
        Fixtures.json(200, ["session": ["id": 1, "status": "running"], "message": "Follow-up prompt sent"])
    }

    func testEveryRequestNamesTheAppAndItsVersionAndClaimsNoModality() async throws {
        let (api, transport) = client([{ _ in Fixtures.json(200, ["sessions": []]) }, sent])

        _ = try await api.sessions(.needsInput)
        _ = try await api.followUp(1, prompt: "Typed, or dictated by the keyboard: the app cannot tell.")

        for request in transport.sent {
            XCTAssertEqual(request.headers["X-Zimmer-Client"], "ios/1.4.2")
            XCTAssertNil(request.headers["X-Zimmer-Input-Modality"])
        }
    }

    func testACarPlayVoiceFollowUpSaysItWasDictatedInTheCar() async throws {
        let (api, transport) = client([sent, sent])

        _ = try await api.followUp(1, prompt: "Ship it.", from: ClientSource.app(version: "1.4.2").onCarPlay(modality: .voiceDictation))
        _ = try await api.followUp(1, prompt: "Yes, go ahead.", from: ClientSource.app(version: "1.4.2").onCarPlay(modality: nil))

        XCTAssertEqual(transport.sent[0].headers["X-Zimmer-Client"], "carplay/1.4.2")
        XCTAssertEqual(transport.sent[0].headers["X-Zimmer-Input-Modality"], "voice_dictation")
        XCTAssertEqual(transport.sent[1].headers["X-Zimmer-Client"], "carplay/1.4.2")
        XCTAssertNil(transport.sent[1].headers["X-Zimmer-Input-Modality"])
        let body = try JSONSerialization.jsonObject(with: transport.sent[0].body ?? Data()) as? [String: String]
        XCTAssertEqual(body, ["prompt": "Ship it."], "the source travels in headers, never in the message")
    }

    func testAnAppWithNoVersionStillNamesItself() {
        XCTAssertEqual(ClientSource.app(version: nil).headers, ["X-Zimmer-Client": "ios"])
    }
}
