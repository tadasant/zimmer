import Foundation
@testable import ZimmerKit

/// A transport that answers from a script and records what it was asked.
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) throws -> HTTPResponse

    private let lock = NSLock()
    private var handlers: [Handler]
    private(set) var requests: [HTTPRequest] = []

    init(_ handlers: [Handler]) { self.handlers = handlers }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let handler: Handler = try lock.withLock {
            requests.append(request)
            guard !handlers.isEmpty else { throw URLError(.cannotConnectToHost) }
            return handlers.removeFirst()
        }
        return try handler(request)
    }

    var sent: [HTTPRequest] { lock.withLock { requests } }
}

enum Fixtures {
    static let base = URL(string: "https://zimmer.example.test")!

    static func json(_ status: Int, _ object: Any, headers: [String: String] = ["content-type": "application/json"]) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: headers, body: try! JSONSerialization.data(withJSONObject: object))
    }

    static func tokens(access: String = "zmr_oat_a", refresh: String = "zmr_ort_r", expiresIn: Int = 3600) -> HTTPResponse {
        json(200, ["access_token": access, "refresh_token": refresh, "expires_in": expiresIn, "token_type": "Bearer"])
    }

    static func signedIn(expiresAt: Date = Date().addingTimeInterval(3600)) -> InMemoryTokenStore {
        InMemoryTokenStore(StoredSignIn(baseURL: base, tokens: OAuthTokens(accessToken: "zmr_oat_old", refreshToken: "zmr_ort_old", expiresAt: expiresAt)))
    }

    /// Cloudflare Access's refusal: an HTML page, not Zimmer's JSON envelope.
    static let accessRefusal = HTTPResponse(
        statusCode: 401,
        headers: ["server": "cloudflare", "content-type": "text/html", "cf-access-aud": "abc123"],
        body: Data("<html>Error ・ Cloudflare Access</html>".utf8)
    )

    static func form(_ request: HTTPRequest) -> [String: String] {
        let body = String(decoding: request.body ?? Data(), as: UTF8.self)
        var fields: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            fields[parts[0]] = parts.count > 1 ? parts[1].removingPercentEncoding : ""
        }
        return fields
    }
}

/// An edge credential that counts what it was asked and renews once.
final class RecordingEdge: EdgeCredential, @unchecked Sendable {
    private let lock = NSLock()
    private var renewals = 0
    let canRenew: Bool

    init(canRenew: Bool) { self.canRenew = canRenew }

    func decorate(_ request: inout HTTPRequest) async {
        let count = lock.withLock { renewals }
        request.headers["cf-access-token"] = "phone-token-\(count)"
    }

    func reauthenticate() async -> Bool {
        guard canRenew else { return false }
        lock.withLock { renewals += 1 }
        return true
    }

    var renewalCount: Int { lock.withLock { renewals } }
}
