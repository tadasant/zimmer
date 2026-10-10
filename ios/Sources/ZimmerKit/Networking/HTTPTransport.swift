import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One HTTP exchange, as data.
///
/// The seam exists so the client can be tested without a network and without `URLProtocol`
/// stubbing: `ZimmerKit`'s tests inject a transport that answers from a script. It is also
/// the reason `ZimmerHTTPClient` compiles on Linux, where `URLSession`'s async API is
/// partial — the URLSession-backed transport is one small file behind this protocol.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public struct HTTPRequest: Hashable, Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?

    public init(url: URL, method: String, headers: [String: String] = [:], body: Data? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Hashable, Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

/// The production transport.
///
/// It never follows a redirect to a Cloudflare Access login page: a machine call refused
/// by the edge must come back as that refusal (`EdgeRefusal`), not as the login page's
/// HTML with a 200 at the end of the redirect chain.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init() {
        self.session = URLSession(configuration: .default, delegate: AccessRedirectGuard(), delegateQueue: nil)
    }

    public init(session: URLSession) {
        self.session = session
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw ZimmerError.transport(URLError(.badServerResponse))
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String {
                headers[name.lowercased()] = value
            }
        }
        return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    }
}

/// Stops a redirect to `*.cloudflareaccess.com`, so the 302 itself is what the caller sees.
final class AccessRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(Self.shouldFollow(request.url) ? request : nil)
    }

    static func shouldFollow(_ url: URL?) -> Bool {
        guard let url else { return false }
        return !EdgeRefusal.isAccessLogin(url)
    }
}
