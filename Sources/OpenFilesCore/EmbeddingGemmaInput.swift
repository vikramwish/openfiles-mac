import Foundation

/// Retrieval prompts documented by the EmbeddingGemma 2 model implementation.
/// Keep the preparation version in the engine identifier when changing these.
public enum EmbeddingGemmaInput {
    public static let dimensions = 768
    public static let maxTokens = 8192
    public static let preparationVersion = "retrieval-v1"
    public static let runtimeVersion = "mlx-0.32.3-lm-48114eedf3c3"

    public static func document(_ text: String) -> String {
        "title: none | text: " + bounded(text)
    }
    public static func query(_ text: String) -> String {
        "task: search result | query: " + bounded(text)
    }
    private static func bounded(_ text: String) -> String {
        String(text.prefix(4000)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
