import Foundation

/// Shared by Spotlight predicates and local ranking, so natural-language queries use one meaning.
public struct FileSearchQuery: Sendable {
    public let terms: [String]
    public let groups: [[String]]
    private let tokenGroups: [[[String]]]
    public var text: String { terms.joined(separator: " ") }
    public init(_ input: String) {
        let stop: Set<String> = ["find", "search", "show", "look", "looking", "for", "me", "my", "all", "the", "a", "an", "of", "to", "please", "files", "file", "documents", "document", "related", "about", "containing", "named", "with", "that", "are", "can", "you", "i", "need"]
        let words = Self.words(input)
        let filenameWords: Set<String>
        if let range = input.range(of: #"[\w-]+\.[a-zA-Z0-9]{1,8}\b"#, options: .regularExpression) { filenameWords = Set(Self.words(String(input[range]))) }
        else { filenameWords = [] }
        let meaningful = words.filter { !stop.contains($0) || filenameWords.contains($0) }
        terms = Array(NSOrderedSet(array: meaningful).array as? [String] ?? meaningful)
        groups = terms.map { term in
            switch term {
            case "australia", "australian": return ["australia", "australian", "gov.au", "mygov", "centrelink", "medicare", "ato", "dfat", "homeaffairs"]
            case "government", "govt", "gov": return ["government", "govt", "gov", "mygov", "centrelink", "medicare", "ato", "dfat", "homeaffairs", "taxation"]
            case "plans", "plan", "planning": return ["plan", "plans", "planning"]
            case "introducing", "launch", "launching": return ["introducing", "launch", "launching", "release"]
            case "photos", "pictures", "images": return ["photo", "photos", "picture", "pictures", "image", "images", "jpg", "jpeg", "png", "heic"]
            case "invoices", "invoice": return ["invoice", "invoices"]
            case "receipts", "receipt": return ["receipt", "receipts"]
            default:
                if term.count > 3 && term.hasSuffix("s") && !term.hasSuffix("ss") { return [term, String(term.dropLast())] }
                return [term]
            }
        }
        tokenGroups = groups.map { $0.map(Self.words) }
    }
    public static func words(_ text: String) -> [String] {
        SearchTokenizer.tokens(text)
    }
    public func coverage(in text: String) -> Double {
        guard !groups.isEmpty else { return 0 }
        let words = Set(Self.words(text))
        let lower = text.lowercased()
        let count = groups.filter { group in group.contains { $0.contains(".") ? lower.contains($0) : words.contains($0) } }.count
        return Double(count) / Double(groups.count)
    }
    public func coverage(words: Set<String>) -> Double {
        guard !groups.isEmpty else { return 0 }
        let hits = tokenGroups.filter { group in group.contains { alias in alias.allSatisfy { words.contains($0) } } }.count
        return Double(hits) / Double(groups.count)
    }
    public static func allows(_ url: URL) -> Bool {
        if let library = FileRules.photoLibrary(containing: url), library != url.standardizedFileURL { return false }
        let excluded: Set<String> = ["library", "node_modules", "site-packages", "__pycache__", "deriveddata", "pods", "carthage", "vendor", "venv", "env", "dist", "build", "indexobjects"]
        let nestedInApp = url.pathComponents.dropLast().contains { $0.hasSuffix(".app") || $0.hasSuffix(".framework") || $0.hasSuffix(".bundle") }
        return !nestedInApp && !url.pathComponents.contains { $0.hasPrefix(".") || excluded.contains($0.lowercased()) || $0.lowercased().hasSuffix(".dist-info") || $0.lowercased().hasSuffix(".egg-info") }
            && !url.path.contains("/Library/Application Support/OpenFiles/")
            && !["installer", "record", "wheel", "metadata"].contains(url.lastPathComponent.lowercased())
    }
    /// Similarity boosts grounded matches; it cannot admit a file with no matching evidence.
    public func score(name: String, content: String, similarity: Double = 0) -> Double? {
        guard !terms.isEmpty else { return nil }
        let nameCoverage = coverage(in: name)
        let combined = coverage(in: name + " " + content)
        guard combined == 1 || (groups.count > 2 && combined >= 0.5 && similarity >= 0.2) else { return nil }
        let phrase = name.localizedCaseInsensitiveContains(text) ? 3.0 : 0
        return phrase + nameCoverage * 5 + combined * 2 + max(0, min(1, similarity)) * 0.4
    }
}

public struct FileSearchMatch: Sendable {
    public let file: FileRecord
    public let score: Double
    public let reason: String
}
