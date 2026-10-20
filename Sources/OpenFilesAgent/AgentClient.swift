import Foundation

/// One model the endpoint offers. `seesImages` is nil when the endpoint does not report
/// input modalities (local servers), so image requests are still attempted for those.
public struct AgentModelInfo: Sendable, Equatable, Identifiable {
    public let id: String
    public let seesImages: Bool?
    public init(id: String, seesImages: Bool? = nil) {
        self.id = id; self.seesImages = seesImages
    }
}

public enum AgentClientError: LocalizedError {
    case transport(String)
    case provider(status: Int, body: String)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .transport(let message): return message
        case .provider(let status, let body):
            let detail = body.isEmpty ? "" : " · \(body)"
            return "The model service returned HTTP \(status).\(detail)"
        case .emptyResponse: return "The model service returned an empty response."
        }
    }
}

/// Minimal OpenAI-compatible client: OpenRouter, the local Hermes proxy, LM Studio or any compatible server.
/// API keys stay in Keychain; requests carry only the planning prompt.
public struct AgentClient: Sendable {
    public var base: URL
    public var apiKey: String?
    public let transport: any AgentHTTPTransport

    public init(base: URL, apiKey: String? = nil, transport: (any AgentHTTPTransport)? = nil) {
        self.base = base
        let trimmed = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = (trimmed?.isEmpty == true) ? nil : trimmed
        self.transport = transport ?? URLSessionAgentTransport()
    }

    public func chat(model: String, system: String, user: String, maxTokens: Int = 4000) async throws -> String {
        try await chat(model: model, system: system, parts: [.text(user)], maxTokens: maxTokens)
    }

    /// Multimodal request: text parts plus optional downscaled image previews.
    public func chat(model: String, system: String, parts: [AgentContentPart], maxTokens: Int = 4000) async throws -> String {
        var request = URLRequest(url: base.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("OpenFiles", forHTTPHeaderField: "X-Title")
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let body: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": parts.map { $0.jsonObject() }]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw AgentClientError.provider(status: response.statusCode, body: String(data: data.prefix(500), encoding: .utf8) ?? "")
        }
        struct Reply: Decodable {
            struct Choice: Decodable { struct Message: Decodable { let content: String? }; let message: Message }
            let choices: [Choice]
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data),
              let content = reply.choices.first?.message.content, !content.isEmpty else {
            throw AgentClientError.emptyResponse
        }
        return content
    }

    /// Models the endpoint offers. `seesImages` is nil when the endpoint does not report
    /// input modalities, so local servers are never blocked on suspicion.
    public func models() async throws -> [AgentModelInfo] {
        var request = URLRequest(url: base.appendingPathComponent("models"))
        request.httpMethod = "GET"
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw AgentClientError.provider(status: response.statusCode, body: String(data: data.prefix(500), encoding: .utf8) ?? "")
        }
        struct List: Decodable {
            struct Item: Decodable {
                struct Architecture: Decodable {
                    let inputModalities: [String]?
                    enum CodingKeys: String, CodingKey { case inputModalities = "input_modalities" }
                }
                let id: String
                let architecture: Architecture?
            }
            let data: [Item]?
        }
        guard let list = try? JSONDecoder().decode(List.self, from: data) else { return [] }
        return (list.data ?? [])
            .map { AgentModelInfo(id: $0.id, seesImages: $0.architecture?.inputModalities.map { $0.contains("image") }) }
            .sorted { $0.id < $1.id }
    }
}
