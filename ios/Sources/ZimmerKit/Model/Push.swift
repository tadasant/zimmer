import Foundation

/// Which APNs environment a device token belongs to. A token only works against the
/// environment it was issued in, so the server stores it with the token: a development
/// build gets sandbox tokens, a TestFlight or App Store build production ones.
public enum APNsEnvironment: String, Sendable, Codable {
    case sandbox, production
}

public enum PushToken {
    /// The device token as APNs addresses it: lowercase hex.
    public static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }
}

/// What a push from Zimmer carries beside its alert (`ApnsService#build_payload`).
public struct PushPayload: Hashable, Sendable {
    public var sessionID: Int?
    public var notificationType: String?

    /// Read from a notification's `userInfo`. Tolerant of the number arriving as a
    /// string, since a payload is JSON and its producer is a separate deploy.
    public init(userInfo: [AnyHashable: Any]) {
        switch userInfo["session_id"] {
        case let id as Int: sessionID = id
        case let id as NSNumber: sessionID = id.intValue
        case let id as String: sessionID = Int(id)
        default: sessionID = nil
        }
        notificationType = userInfo["notification_type"] as? String
    }
}

/// A device registration as the server echoes it.
public struct DeviceRegistration: Hashable, Sendable, Decodable {
    public var id: Int
    public var environment: String

    struct Response: Decodable {
        let apns_device: DeviceRegistration
    }
}
