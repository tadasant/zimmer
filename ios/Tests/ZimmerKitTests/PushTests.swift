import XCTest
@testable import ZimmerKit

final class PushTests: XCTestCase {
    func testTheDeviceTokenIsLowercaseHex() {
        XCTAssertEqual(PushToken.hex(Data([0x00, 0xAB, 0x10, 0xff])), "00ab10ff")
    }

    func testThePayloadYieldsTheSessionWhateverShapeItsNumberArrivesIn() {
        XCTAssertEqual(PushPayload(userInfo: ["session_id": 1038, "notification_type": "needs_input"]).sessionID, 1038)
        XCTAssertEqual(PushPayload(userInfo: ["session_id": NSNumber(value: 7)]).sessionID, 7)
        XCTAssertEqual(PushPayload(userInfo: ["session_id": "42"]).sessionID, 42)
        XCTAssertNil(PushPayload(userInfo: ["aps": ["alert": "hi"]]).sessionID)
        XCTAssertEqual(PushPayload(userInfo: ["notification_type": "needs_input"]).notificationType, "needs_input")
    }

    func testRegisteringAndUnregisteringHitTheDeviceEndpoints() async throws {
        let transport = ScriptedTransport([
            { _ in Fixtures.json(201, ["apns_device": ["id": 1, "environment": "production"]]) },
            { _ in HTTPResponse(statusCode: 204, headers: ["x-request-id": "r"]) },
        ])
        let api = ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport)
        let token = String(repeating: "ab", count: 32)

        try await api.registerDevice(token: token, environment: .production, deviceName: "iPhone", appVersion: "0.1.0 (3)")
        try await api.unregisterDevice(token: token)

        XCTAssertEqual(transport.sent.map(\.method), ["POST", "DELETE"])
        XCTAssertEqual(transport.sent[0].url.path, "/api/v1/apns_devices")
        let body = try JSONSerialization.jsonObject(with: transport.sent[0].body ?? Data()) as? [String: String]
        XCTAssertEqual(body?["token"], token)
        XCTAssertEqual(body?["environment"], "production")
        XCTAssertEqual(body?["device_name"], "iPhone")
        XCTAssertEqual(transport.sent[1].url.path, "/api/v1/apns_devices/\(token)")
    }
}
