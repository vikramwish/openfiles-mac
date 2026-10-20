import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol CloudHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Returns a temporary file owned by the caller, which must remove it.
    func download(_ request: URLRequest) async throws -> (URL, HTTPURLResponse)
}

/// Redirects are handled explicitly by CloudClient so bearer tokens cannot follow them.
public final class URLSessionCloudTransport: CloudHTTPTransport, @unchecked Sendable {
    private let session: URLSession
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        session = URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CloudError.invalidResponse }
        return (data, response)
    }
    public func download(_ request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        let (url, response) = try await session.download(for: request)
        guard let response = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: url)
            throw CloudError.invalidResponse
        }
        return (url, response)
    }
}

private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
