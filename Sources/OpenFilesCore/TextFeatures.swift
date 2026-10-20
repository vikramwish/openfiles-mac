import Foundation

/// One normalization implementation for document postings, query plans, and graph edges.
/// ASCII documents bypass Unicode folding and Foundation's component-array allocation.
enum SearchTokenizer {
    static func tokens(_ text: String, limit: Int = .max) -> [String] {
        guard limit > 0 else { return [] }
        var result: [String] = []
        result.reserveCapacity(min(256, limit))
        if text.utf8.allSatisfy({ $0 < 128 }) {
            var word: [UInt8] = []; word.reserveCapacity(32)
            for raw in text.utf8 {
                let byte = (65...90).contains(raw) ? raw + 32 : raw
                if (97...122).contains(byte) || (48...57).contains(byte) { word.append(byte) }
                else if !word.isEmpty {
                    result.append(String(decoding: word, as: UTF8.self)); word.removeAll(keepingCapacity: true)
                    if result.count == limit { return result }
                }
            }
            if !word.isEmpty { result.append(String(decoding: word, as: UTF8.self)) }
        } else {
            let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            var word = String.UnicodeScalarView()
            for scalar in folded.unicodeScalars {
                if CharacterSet.alphanumerics.contains(scalar) { word.append(scalar) }
                else if !word.isEmpty {
                    result.append(String(word)); word = String.UnicodeScalarView()
                    if result.count == limit { return result }
                }
            }
            if !word.isEmpty { result.append(String(word)) }
        }
        return result
    }
}

struct TextFeatures: Sendable {
    let terms: [String]
    let wordUnits: Int
}

/// Shared by bounded workers. Duplicate contents tokenize once, independently of model input.
/// Only a content hash and derived terms are retained, with a hard memory-entry limit.
actor TextFeatureCache {
    private var entries: [String: TextFeatures] = [:]
    private var slots = Array<String?>(repeating: nil, count: 512)
    private var cursor = 0
    func resolve(_ text: String) -> (features: TextFeatures, reused: Bool) {
        let key = IndexText.key(text, engine: "search-terms-v1")
        if let cached = entries[key] { return (cached, true) }
        let words = SearchTokenizer.tokens(text, limit: 6000)
        let features = TextFeatures(terms: Array(Set(words)).sorted(), wordUnits: words.count)
        if let expired = slots[cursor] { entries.removeValue(forKey: expired) }
        slots[cursor] = key; cursor = (cursor + 1) % slots.count
        entries[key] = features
        return (features, false)
    }
}
