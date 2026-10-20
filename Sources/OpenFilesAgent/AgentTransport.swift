import Foundation
import OpenFilesCore

/// OpenAI-compatible HTTP transport, mockable in checks like the cloud transport.
public protocol AgentHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public final class URLSessionAgentTransport: AgentHTTPTransport, @unchecked Sendable {
    private let session: URLSession
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 300
        session = URLSession(configuration: configuration)
    }
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenFilesCore.OpenFilesError.message("The model service did not respond.") }
        return (data, http)
    }
}
