import Foundation

/// A reason Live Mode cannot connect that no retry will fix: something a person has to put
/// right first, somewhere other than the app.
///
/// OpenAI says so in an `error` event on the Realtime socket and then closes it. Read only as
/// the close, every attempt looks like a dropped connection ("Socket is not connected") and the
/// car retries it as one. Read from the event, the call ends at once with the real reason, and
/// the car stops retrying and says what is wrong (`LiveRetry.gaveUp(blockedBy:)`).
///
/// Only errors that are certain to come back on the next attempt belong here. A wrong guess
/// costs a driver one tap; a missed one costs the endless retry this exists to stop, so the
/// list stays narrow and anything not on it is retried as before.
public enum LiveBlock: String, Hashable, Sendable {
    /// The OpenAI account has no credits left, or has hit its billing limit.
    case outOfCredits

    /// The `error` codes and types that mean the OpenAI account cannot pay for the call.
    static let creditCodes: Set<String> = [
        "insufficient_quota", "credit_balance_exhausted", "billing_hard_limit_reached", "billing_not_active",
    ]

    /// The block an OpenAI Realtime event reports, or nil for any other event or error.
    public init?(realtimeEvent event: JSONValue) {
        guard event["type"]?.string == "error" else { return nil }
        let error = event["error"]
        let said = [error?["code"]?.string, error?["type"]?.string].compactMap { $0 }
        guard said.contains(where: Self.creditCodes.contains) else { return nil }
        self = .outOfCredits
    }

    /// What the phone shows and the call's log records.
    public var message: String {
        switch self {
        case .outOfCredits:
            return "OpenAI is out of credits, so Live Mode can't connect. Add credits to the OpenAI account, then try again."
        }
    }

    /// The car's tile, longest first as CarPlay chooses among them.
    public var titleVariants: [String] {
        switch self {
        case .outOfCredits: return ["OpenAI is out of credits", "No credits"]
        }
    }
}
