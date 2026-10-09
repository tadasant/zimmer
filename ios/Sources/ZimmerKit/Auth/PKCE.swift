import Foundation

/// An RFC 7636 verifier and its S256 challenge.
///
/// The verifier never leaves the phone until the token request, so a code intercepted on
/// its way back through the app's URL scheme is worth nothing to whoever intercepted it.
public struct PKCEPair: Hashable, Sendable {
    public let verifier: String
    public let challenge: String

    /// 32 random bytes, base64url: a 43-character verifier, which is what Zimmer's
    /// authorization server expects of the challenge too (`CHALLENGE_FORMAT`).
    public static func generate() -> PKCEPair {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        let verifier = base64URL(bytes)
        return PKCEPair(verifier: verifier, challenge: challenge(for: verifier))
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(SHA256Digest.hash(Array(verifier.utf8)))
    }

    public init(verifier: String, challenge: String) {
        self.verifier = verifier
        self.challenge = challenge
    }

    static func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// An unguessable `state`, the same shape as a verifier.
    public static func randomState() -> String {
        generate().verifier
    }
}
