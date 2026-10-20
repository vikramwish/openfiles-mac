import Foundation
import MLX
import MLXEmbedders
import MLXLMCommon
import OpenFilesCore
import Tokenizers

/// One loaded model is shared by the query backend and all indexing workers.
/// The container serializes inference and returns only evaluated Swift values.
public actor EmbeddingGemmaBackend: EmbeddingBackend {
    public nonisolated let identifier: String
    public nonisolated let displayName = "EmbeddingGemma 2 · local MLX · 768 dimensions"
    private let container: EmbedderModelContainer
    private var lastFailure: String?

    private init(checkpoint: EmbeddingGemmaCheckpoint, container: EmbedderModelContainer) {
        identifier = checkpoint.identifier
        self.container = container
    }

    public static func load(directory: URL) async throws -> EmbeddingGemmaBackend {
        let inspection = Task.detached(priority: .utility) {
            try EmbeddingGemmaCheckpoint.inspect(directory: directory)
        }
        let checkpoint = try await withTaskCancellationHandler { try await inspection.value } onCancel: { inspection.cancel() }
        // Local-directory loading has no downloader and never uploads file contents.
        // MLX loads only the text component; media encoders are lazy and never invoked here.
        let container = try await EmbedderModelFactory.shared.loadContainer(
            from: checkpoint.directory, using: LocalTokenizerLoader())
        let backend = EmbeddingGemmaBackend(checkpoint: checkpoint, container: container)
        // Fail selection before saving it if weights/tokenizer cannot actually perform retrieval.
        _ = try await backend.embed(EmbeddingGemmaInput.query("Find a document"))
        return backend
    }

    public func vector(for text: String) async -> [Double]? {
        await infer(EmbeddingGemmaInput.document(text))
    }
    public func queryVector(for text: String) async -> [Double]? {
        await infer(EmbeddingGemmaInput.query(text))
    }
    public func failureReason() -> String? { lastFailure }

    private func infer(_ input: String) async -> [Double]? {
        do {
            let vector = try await embed(input)
            lastFailure = nil
            return vector
        } catch {
            lastFailure = "EmbeddingGemma 2 inference failed: \(error.localizedDescription)"
            return nil
        }
    }
    private func embed(_ input: String) async throws -> [Double] {
        try Task.checkCancellation()
        return try await container.perform { context in
            try Task.checkCancellation()
            let ids = Array(context.tokenizer.encode(text: input, addSpecialTokens: true).prefix(EmbeddingGemmaInput.maxTokens))
            guard !ids.isEmpty else { throw OpenFilesError.message("The model tokenizer returned no tokens.") }
            let output = context.model(MLXArray(ids)[.newAxis], positionIds: nil, tokenTypeIds: nil, attentionMask: nil)
            // EmbeddingGemma 2 already projects and pools. Its factory selects .none pooling.
            let pooled = context.pooling(output, normalize: true)
            try MLX.checkedEval(pooled)
            let vector = pooled.asArray(Float.self).map(Double.init)
            guard vector.count == EmbeddingGemmaInput.dimensions, vector.allSatisfy(\.isFinite),
                  vector.contains(where: { $0 != 0 }) else {
                throw OpenFilesError.message("EmbeddingGemma 2 returned an invalid embedding; expected 768 finite, nonzero dimensions.")
            }
            try Task.checkCancellation()
            return vector
        }
    }
}

/// Equivalent to MLX's documented Hugging Face tokenizer bridge, without macro,
/// network downloader, or text-generation dependencies in the application target.
private struct LocalTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        LocalTokenizer(upstream: try await AutoTokenizer.from(modelFolder: directory))
    }
}

private struct LocalTokenizer: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] {
        try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }
}
